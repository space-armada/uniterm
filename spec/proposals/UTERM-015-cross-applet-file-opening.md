# UTERM-015: Cross-Applet File Opening

**Status:** implemented
**Created:** 2026-11-03
**Updated:** 2026-11-26

## Dependencies

- UTERM-001: the pane tree, the applet contract, and the terminal applet the router places panes in
- UTERM-002's command registry and UTERM-013: File > Open is a registry command, and its key falls under shortcut
  ownership
- UTERM-003 M3: M5's `uniterm open` uses the `uniterm` command and its listener
- UTERM-004 M1 and M3: M4's path-reading power builds on caller identity and shared command dispatch
- UTERM-004 M4: M1's check that a routed split never joins a group a controller owns. It runs against a real
  controller-owned group
- UTERM-004 M6: M4's grants, M7's approvals for senders other than Apple's openers, and M5's session approval all use
  its approval flow and pending indicator. M5 and M7 started after it, and it has landed. Amended 2026-11-17; see
  Decision Log.

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
defines the path-reading power under ADR-14, which lets a controller ask an applet to read a path inside an explicit
directory scope.

## Motivation

UTERM-009 settled that viewers open files from inside their own pane, with an open panel or a drop. It left app-level
opening to one cross-applet proposal, because UTERM-006, UTERM-007, UTERM-008, and UTERM-009 all open files, and
deciding it inside one applet would change the factory every applet implements. Its revisit hook requires this proposal
to be filed before a second viewer among UTERM-006 to UTERM-008 starts its first milestone. UTERM-006 M1 is gated on it
directly.

UTERM-006 also settled that asking an applet to read a path is a power of its own under ADR-09 (superseded by
ADR-14), apart from pane control. ADR-09 lists no such power, and UTERM-005, UTERM-006, UTERM-007, and UTERM-009 each
need the same one. One definition keeps them from diverging.

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

Asking an applet to read a path on a controller's behalf is its own power under ADR-14. This proposal defines it once
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
  Allow once, session, and remembered approvals as for every other power. The power must stand for a read to run,
  and an Allow once answer does not make it stand, so a controller that reads needs Allow for This Run or a remembered
  approval. Amended 2026-11-16; see Decision Log.
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
- Every other sender goes to UTERM-004's pending indicator, named from its verified signing information. The user can
  allow once, or allow for the session. A session grant binds to the sender's audit-token PID and PID version, and its
  label says it covers everything that app sends until it quits, as UTERM-004's OSC 52 approval says for a terminal
  session. It lives in memory only. It ends when the sender exits or starts another executable, and nothing is
  remembered after that. A Deny of an app lasts until it ends as well. Amended 2026-11-17; see Decision Log.
- A go-between, such as `/usr/bin/open` or a Launch Services helper, a sender that cannot be identified, and a sender
  with no signing identifier to name get Allow once only. So does every other Apple-signed program that is not an
  opener, since any program can drive one. M2 checked for an attribute that names the originator, and found none. An
  event sent by `open -a` carries `keyActualSenderAuditToken`, and it names the Launch Services UI agent, not the
  program that ran `open`. The authority therefore reads only the sender's own audit token. Amended 2026-11-17; see
  Decision Log.
- One event is one operation that names every file in it.
- A prompt for an unknown sender says the sender is unknown and lists every full path.
- Nothing about the open waits on a window. A question that still waits for the user's answer is not an open waiting
  for layout restore, so the default window opens and the question has a window to show in. Amended 2026-11-17; see
  Decision Log.
- The question says that a new window may open. Opening a window is a power of its own under ADR-14, and a batch, a
  lack of room, or no open window each call for one. The one approval covers it. Amended 2026-11-17; see Decision
  Log.
- A refusal never passes silently. A Deny, a sender that quit before the user answered, an event that names no local
  file, and a pending indicator with no room each post a bounded, coalesced message that names the sender and says
  why, and touch no path. Amended 2026-11-17; see Decision Log.
- A program with Automation consent over Finder can make Finder the sender. The event carries no originator, so this
  cannot be closed. It is accepted under ADR-14's statement that uniterm gives no isolation from the user's own
  processes.
- M2 recorded which sender `open -a` reports, cold and warm. M8 records what a cold-launch Finder open and a warm one
  report. If Finder and `open -a` cannot be told apart, this question reopens. Amended 2026-11-03; see Decision
  Log.

Rationale: accepting every sender lets any program open panes with no grant, which ADR-14 forbids. Refusing every
other sender breaks third-party file managers and launchers with no recovery. Remembered trust in a launcher such as
Alfred or Raycast would trust every script it runs, which ADR-14 forbids for a shared interpreter. UTERM-004 also
remembers only powers a controller declares at startup, and an Apple Event sender declares none. Allow once alone
would ask a launcher user on every open, the habitual approval ADR-14's context warns against. A session grant honestly
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

Superseded in part by UTERM-036; see Decision Log.

Original question: where the router places the pane a routed file opens in.

Decision: beside the pane the request came from, in a new pane that no controller owns. A new window holds only the
routed pane.

- The anchor is the pane the request came from. A terminal click anchors to the clicked pane. `uniterm open` from a
  terminal session anchors to that session's pane, by the source-pane binding UTERM-004 settles. File > Open anchors
  to the focused pane of the window whose menu ran it. Finder, the Dock, and other Launch Services senders anchor to
  the focused pane of the most recently key window. Only Apple's openers bring that window forward. An approved
  sender that is not an opener raises nothing and takes no focus. A `uniterm open` from a caller in no terminal
  session anchors to the same pane. A routed split from a program's open raises no existing window, since a program's
  open takes no focus. Amended 2026-11-17; see Decision Log.
- The routed pane is new and disconnected, and a routed split never joins a group a controller owns. A routed open
  never replaces the source of an existing pane.
- A pane or window that a program's open makes takes no focus, per ADR-12. A new window that holds only the routed pane
  is ordered in front without becoming key, and the app is not activated, so the user can see it and keeps typing where
  they were. File > Open, a click on a terminal link, and Apple's openers are the user's act, and their routed pane
  takes the focus as before. Amended 2026-11-17; see Decision Log.
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
- A relative path clicked in the terminal is refused with a status message. Only an absolute path or a `file:`
  hyperlink opens. A path that starts with `~` counts as relative. Amended 2026-11-17; see Decision Log.

Rationale: the file's folder comes from the request, so it is the same in a split and in a new window, and for every
entry point. The focused pane's directory would depend on which pane had focus when a Finder event arrived. A relative
argument to `uniterm open` means what the user's shell means by it, and resolving it in the command keeps any CLI
state out of the app. A clicked relative path may have been printed by a remote `ls` over ssh, or before a `cd`.
Shell integration gives no signal that output came from a remote host, so resolving it against any local directory can
open the wrong file. Leaves undone: clicking `notes.txt` in `ls` output opens nothing and says why in the status bar.

### Who may run `uniterm open`

Original question: opening a pane from a process is a control effect under ADR-14. Which approval a `uniterm open`
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
- The reply never tells missing, unsupported, and denied apart without the path-reading power for that path. The
  command gets its reply once the user allows the request, before any path is looked at, so a file that opened, one
  that is missing, and one no applet opens all get the same reply, and the reply carries no content. What went wrong
  shows only in the app's own status message. A request the user denies gets the refused status, since the user's own
  answer says nothing about a file. Amended 2026-11-16; see Decision Log.
- The question says that a new window may open. Opening a window is a power of its own under ADR-14, and a batch, a
  lack of room, or no open window each call for one. The one approval covers it. Amended 2026-11-17; see Decision
  Log.
- Commands that run in no terminal session share one bound on waiting questions. Each is a new connection that holds
  a listener slot while its question waits, so past the bound a command is refused at once with exit status 77, which
  frees its slot. The questions already waiting stay. Amended 2026-11-17; see Decision Log.

Rationale: a controller grant would require remote control on the source pane, and the only signed party is uniterm's
own helper, a shared go-between ADR-14 forbids trusting. That is stricter than the Launch Services path, so a refused
program would use `open -a` instead. Treating it as the user's act gives any process panes with no grant, against
ADR-14, and looser than the Launch Services path. A session grant on the helper's PID would cover one call only, under
a false label.

### Who may open by terminal click

Original question: a Cmd-click is the user's gesture, but a program chose the text. An OSC 8 hyperlink's text can read
`README.md` while its target is `file:///Users/me/Documents/tax.pdf`. Who authorizes a click.

Decision: a click is the user's act only on a target uniterm showed before the click, opened only if it is exactly
that file, and never on output that may be remote.

- On Cmd-hover, uniterm shows the target as text: the absolute path, or a hyperlink's target rather than its text.
  Showing it touches no file. libghostty's mouse-over-link action reaches the app through an addition to the terminal
  surface protocol, per ADR-01, beside its open-URL action. A `file:` link is shown as its decoded path. A link with a
  query, a fragment, credentials, or characters that could show as another path is refused. Amended 2026-11-17; see
  Decision Log.
- The click is bound to the string that was shown. After the open, the opened descriptor's real path must match that
  string, after normalizing the system's links into `/private`, such as `/tmp` to `/private/tmp`, or the open is
  refused. A printed symlink to another file therefore opens nothing. Amended 2026-11-17; see Decision Log.
- Output written while a remote client ran in the foreground keeps a remote marker, even after the client exits. The
  remote clients are `ssh`, `mosh`, and the others M6 lists, and an OSC 7 report that names another host. Where the
  pinned libghostty cannot mark rows, the marker covers the whole terminal tab for the rest of its session, since each
  tab is its own session. A click on marked output shows that the output may be remote and opens nothing. Amended
  2026-11-17; see Decision Log.
- M6 names where each signal comes from: the pinned libghostty, an addition to the terminal surface protocol, or a
  process lookup on the pane's child.

Rationale: accepting every click lets a program open any file with no grant, looser than the Launch Services path.
Splitting hyperlinks from bare paths rests on a distinction libghostty does not report, and on reading text a program
can hide. Inserting `uniterm open` on the command line types program-chosen text into whatever owns the terminal, such
as `vim` or a remote shell. Resolving the target on hover would touch a program-chosen path before any authorization.
Signals read at click time miss a remote `ls` that is still in the scrollback after `exit`. Leaves undone: remote
clients M6 does not list, such as `kubectl exec`, `docker exec`, and `ssh` inside a local tmux, still look local. On
a libghostty that cannot mark rows, one remote session turns off clicks in that tab.

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
- **M2's sender measurement reopens the Launch Services decision** — resolved. M8 recorded that Finder reports
  `com.apple.finder` and the Dock `com.apple.dock`, cold and warm, and `open -a` never does. The decision stands, and
  M7 built the approvals. Amended 2026-11-17; see Decision Log.
- **Parts of the design wait on unbuilt work** — resolved. UTERM-004 M6 and UTERM-003 M3 are built and shipped. M5
  built `uniterm open` and M7 built the approvals for other Launch Services senders on them. Nothing waits. Amended
  2026-11-17; see Decision Log.
- **Hover and the remote marker depend on the pinned libghostty** — likelihood: medium, impact: low. Marking rows may
  need a patch or a pin bump. Mitigation: M6 names each signal's source, and without row marks the marker covers the
  whole tab. The patch M6 carries is small, and it is rebuilt with every pin bump. Amended 2026-11-17; see Decision
  Log.
- **No viewer has a path-reading controller command yet** — likelihood: high, impact: low. The text, data, image,
  and map viewers exist and declare their types, so the router works with real applets. None has a controller command
  that reads a path, so M4 is proven on fixture applets. Mitigation: the first viewer command that reads a path goes
  through the same host service and its tests. Amended 2026-11-17; see Decision Log.

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

**Status:** DONE

Amended 2026-11-17; see Decision Log.

- Starts after UTERM-004 M1, M3, and M6
- A controller command that makes an applet read a path is refused without the power, and with a path outside its
  scope
- A symlink or a rename between check and open cannot reach a file outside the scope
- Missing, unsupported, and denied paths outside the scope return the same error
- A pane whose source lies outside a controller's scope sends that controller no path or content from it
- Revoking the grant stops queued reads, per ADR-14
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
- One connection can have only a few path walks running at once, and a walk past the bound is refused as any path
  outside the scope is

**As built:**

- The host service is built and proven on fixture applets. No controller command reads a path today, so nothing in
  production calls it yet. The first places it could serve are two open bugs that break the same rule, each of which
  needs its own design call:
  [the script snapshot reads a program-chosen path](../bugs/20261116-script-snapshot-reads-program-chosen-path.md)
  and
  [sent Markdown images escape the sent folder](../bugs/20261115-sent-markdown-images-escape-sent-folder.md).
  Neither is fixed here.
- Divergences and best guesses are in the Decision Log, 2026-11-16, M4 best guesses. The two that change a reader's
  expectation: the walk runs off the main thread before a command is queued, and an Allow once answer does not let a
  controller read.
- The permission joined descriptor format 2 with no new format. An older build refuses a kind it does not know, in a
  descriptor and in a policy file, where it reads as newer. The skew test stands in for that build with a kind the
  current one lacks, and pins that neither format number moved.
- The scope is its own type, and a protected place is left out of a scope that contains it. Coverage compares scopes
  without following links, name by name after normalization, so a different spelling can only make a request ask
  again. The open compares by the volume's own case rule. The list is one type with one test.
- The scoped open never looks at a name outside the scope. A test counts the names it looked up, and none was outside.
  A link target outside the scope, absolute or relative, ends the walk before any of it is looked up. Pipes and
  devices are judged by `fstatat` and never opened, and a pipe swapped in after the look is opened without blocking and
  refused. A rename and a link swap between the look and the open are tested with a hook in that gap.
- Case and normalization tests follow the volume they run on. On a case-insensitive volume a name in another case
  opens, and on a case-sensitive one it does not. The suite did not run on a case-sensitive volume.
- A path argument type is part of the applet command schema. The dispatcher hands the applet an opened file or folder
  and a null in place of the path. A folder opens each member through the same check. A caller that brings no opens,
  such as an exec driver, cannot name a path.
- The approval panel and the Controllers window name every protected place a scope lies in, names, or leaves out. A
  scope directory that is a link into a protected place is named too, since the links are resolved off the main thread
  once a review is queued or a row first shows. A review that asks to read paths says that Allow Once refuses its
  reads, and a run in that state is told so, apart from the uniform refusal for a path outside the scope.
- Delivery stays bounded for the main thread. The roots a scope resolved to are kept with each opened path, so the
  re-check at delivery is string work and one `F_GETPATH` on an open descriptor, and a changed scope refuses. Listing
  a folder and opening a member are async and run off the main thread.
- Protected places match by Unicode case folding whatever the volume's rule, so a spelling that only the fold equates
  with a protected place, such as a long s in Desktop, is never looked up. The fold uses the standard library's
  tables. Foundation's own folding made an unrelated find test of the text viewer, which counts main-actor turns
  while a search runs, fail whenever it ran first in the full suite.
- Redaction covers the pane list and the text viewer's wait replies, scroll bounds, and reload failures. Terminals are
  unchanged. Content a controller sent itself is shown to it, found by the folder it waits in. The pane list hides
  titles and the directory for every caller outside the scope, ordinary scripts included.
- A connection has at most 4 walks running. The walk opens a program-chosen path, which never returns on a dead
  network mount, and each stuck walk parks a thread. A walk past the bound fails with the uniform answer for a path
  outside the scope. A test injects an opener that blocks, and failed before the bound. The members of a folder
  source are opened by the applet for the command it was delivered, so they are not counted again.
- The one reader of a descriptor's real path is `DescriptorPath` in the source access module. The terminal's click
  check uses it too, so the two never decode the system's answer differently. A test pins it.
- Residuals. The redaction check compares the path the viewer recorded, so a user-opened link inside a scope whose
  target lies outside it is shown. Resolving it would read the disk on the main thread. A hard link inside a scope
  reaches a file
  outside it, as the Risks entry accepts. A folder's members are checked against the scope held when the command was
  delivered.
- No `test-cost` target exists in this repo. The new test classes ran in under 1 s each in the package suite:
  `ScopedOpenTests` 13 tests in 0.5 s, `ReadScopeTests` 8, `ControlDispatcherPathTests` 8 in 0.1 s, and
  `PathReadWindowTests` 3 in 0.2 s.
- UI test classes that script a window or a text viewer were not run by this milestone: `ScriptRunUITests`,
  `ReplUITests`, `PresentationUITests`, `TextViewerUITests`, `ControllerRunUITests`, and `ControllerConsentUITests`.

### M5: `uniterm open`

Superseded in part by UTERM-036; see Decision Log.

**Status:** DONE

Amended 2026-11-17; see Decision Log.

- Starts after UTERM-003 M3, UTERM-004 M6, and this proposal's M4
- `uniterm open <path>` opens the path through the router, with the authority "Who may run `uniterm open`" settles
- `uniterm open a b c` is one approval and one batch, with one summary message for failures
- A session grant ends with its terminal session or pane, and a restored pane never carries it
- A caller outside any terminal session, a tmux pane included, gets Allow once only
- Nothing touches a path before its open is authorized, so an unapproved request never raises a macOS privacy prompt
- A relative path resolves against the command's physical working directory, and a deleted one fails in the command
- The reply carries no file content
- A pane or window that `uniterm open` makes takes no focus, a routed split raises no existing window, and a new
  window is never made key and never activates the app
- An old `uniterm` command with a new app, or the reverse, is refused at the handshake
- The question says that a new window may open
- A loop of commands outside any terminal session cannot hold more than a fixed share of the listener's slots and
  the pending rows

**As built:**

- Divergences and best guesses are in the Decision Log, 2026-11-16, M5 best guesses. The two that change a reader's
  expectation: exit status 0 says only that the app took the request, and a program's open takes no focus and raises no
  existing window.
- The command is `uniterm open [--socket PATH] [--] path...`. It joins a relative path to its own working directory
  as a string, and calls `realpath` on that directory only. It never looks at a target. Only absolute paths cross the
  socket, and the wire reader refuses a relative one from a raw peer. A path or a count that does not fit is refused
  in the command with a message, never cut.
- The protocol version is 13. The begin and its reply are new messages, and an old command or an old app is refused at
  the hello, tested in both directions.
- The host asks through the pending indicator for every open that no session grant covers. A command in a terminal
  session is offered Allow once and Allow for This Terminal Session. A command in no session, including one in tmux or
  screen, is offered Allow once and Deny only. So is a command whose session's pane can no longer be named, since the
  question could not tell the user which session a grant would cover. The row says so with a general once-only flag,
  which a session answer cannot widen, and which the Launch Services approvals reuse.
- A session grant binds the session root and its generation. It lives in memory only. It ends when the root is
  removed and when its window closes, and it stops covering when the registry holds another generation, though the
  entry stays until one of the first two. A session allow leaves the session's other waiting questions pending, each
  checked again when answered. A denial of a session lasts for it,
  until Ask Again or the pane closes. A command that exits while its question waits takes its row with it.
- Nothing looks at a path before the answer. The router's one look at a path is now an injected reader, and a test
  that runs the real host, coordinator, router, and windows records every look. A pending, denied, withdrawn, and
  exited request each leave the record empty. An allowed one records the path.
- The approval lists every full path with control and direction characters written out, and the count. One approval
  covers the router's confirmation above 10 files, through an option on the route that skips it. The option also turns
  off focus. Failures post one summary in the app's status message.
- A program's open waits for layout restore in the coordinator's queue, as a Launch Services open does.
- New test classes ran in under 1 s each in the package suite. See the Decision Log entry for the times.
- UI test classes that this milestone adds or touches: `ScriptOpenUITests`, new. Nobody has run them. The shipped
  command's own `open` is covered by a test in `CommandHelperSandboxTests`, which `make test-helper-sandbox` runs.
- The question says "A new window opens when a batch or a lack of room calls for one", for a command in a session
  and for one outside any. Opening a window is a power of its own under ADR-14, and the first wording said only "each
  in a new pane".
- Commands outside any session ask under a requester of their own, and they share one bound of
  `maxRowsPerRequester` rows. Without it, 32 commands held every listener slot and 32 rows while their questions
  waited, and no script could connect. The 17th command is refused at once with the busy text and exit status 77.
  The regression test failed first, with 20 rows. Commands in a session keep their own requester, since the pane they
  ask for bounds them.
- A peer filed [a bug](../bugs/20261116-script-opened-pane-takes-focus.md) that `uniterm/open-pane` takes focus. It is
  a different function from the route this milestone changed, and it is not fixed here.

### M6: Terminal clicks

**Status:** DONE

Amended 2026-11-17; see Decision Log.

- Cmd-hover on an absolute path or a local `file:` hyperlink shows its target as text, with no file-system access
- Cmd-click opens exactly the shown target through the router, and a printed symlink whose real path differs opens
  nothing
- A path a remote `ls` printed opens nothing, even after `exit` returns to the local shell
- The list of remote clients is written down, and each remote signal's source is named
- A relative path clicked in the terminal is refused
- A `file:` hyperlink naming another host never opens a local file
- A Cmd-click on a web URL or another non-file scheme does nothing
- The open-URL and mouse-over-link actions reach the app through the terminal surface protocol
- A click while an earlier one in the same tab is still being checked is refused with a message, so a click loop
  cannot park a thread per click

**As built:**

- Divergences and best guesses are in the Decision Log, 2026-11-17, M6 best guesses. The two that change a reader's
  expectation: a remote client or an OSC 7 from another host turns off clicks for the whole tab for the rest of its
  session, and the clicked path is opened once to verify it and again by the viewer.
- Ghostty patch `003-remote-host-and-raw-link-text.patch` makes two changes. A non-local OSC 7 is reported as a new
  `REMOTE_HOST` action that carries the host, and libghostty still does not adopt the path. A click on link text
  reaches the embedder as printed, since the patch removes the join to the terminal's working directory and the access
  check. `make ghostty` rebuilds with it. The integration test that clicks relative text failed on a build with only the
  first change, and passed with both.
- The surface protocol gained `linkHovered`, `linkOpenRequested`, and `remoteHostReported`. libghostty's open-URL action
  is always taken, so its own opener never runs. `link-url`, `link-osc8`, and `link-previews` are set to `true` in the
  terminal config and join its allow list for `true` only. The REPL pane receives the events and ignores them.
- The click rules live in the terminal applet. A click is classified from its text alone, with no file access. An
  absolute path and a `file:` link whose host is empty or `localhost` are the only openable text. The path of a `file:`
  link is percent-decoded. A relative path, a path that starts with `~` or `$`, and a link to another host are refused
  with a status message. Any other scheme does nothing, with no message. Text with control, format, line-separator,
  paragraph-separator, or unassigned characters is refused as not a plain path. So is a `file:` link with a query, a
  fragment, or credentials. The overlay could not show them as they are.
- A click opens only text equal to the last hover. Anything else is refused with a message. The hover is kept per tab.
- Before routing, the path is opened off the main thread. A `lstat` first refuses anything but a regular file or a
  folder, and a link. The open uses `O_NOFOLLOW`, `O_NONBLOCK`, `O_NOCTTY`, and `O_CLOEXEC`. The descriptor must be the
  file `lstat` saw. Its real path from `F_GETPATH` is then compared with the shown path. Both go through one
  normalization, which maps `/tmp`, `/var`, and `/etc` to `/private/...` and drops trailing slashes. Any other spelling
  difference refuses, including a doubled slash, a dot segment, and a case or link difference. A folder takes the same
  check. The verified path goes to `RoutedOpener` as a click from the clicked pane. It takes focus, as File > Open does.
- The overlay is at the bottom left of the terminal. It shows the decoded absolute path, middle-truncated by width, in
  the monospaced system font on the `mantle` surface with an `overlay0` border. It passes every click through. Its
  label's accessibility identifier is `terminal-link-preview`. It shows nothing for a relative path, a web address, or a
  link to another host. When the tab is marked remote it shows "This output may be from another host. A click opens
  nothing." and no target. A refusal after a click goes to the pane's status bar as a warning.
- The remote marker covers the whole tab, since libghostty cannot mark rows, and it lasts as long as the tab's session.
  Each tab is its own session, so a second tab is unaffected. It never clears. Two signals set it:
  - A remote client in the session's process tree. The list is `ssh`, `mosh-client`, `mosh`, `telnet`, `rlogin`,
    `rsh`, `et`, and `autossh`. It is one set in `RemoteClients`, and a test pins it. A process matches by the name the
    kernel keeps or by the last component of its executable path. The source is a process lookup on the pane's child:
    the session root from the existing child-started event, then `proc_listchildpids` for the tree. Every process in the
    tree is watched for fork, exec, and exit through the kernel's process events, which is EVFILT_PROC through
    `DispatchSource`. Each event rescans the tree off the main thread. A process is watched before its name is read,
    so an exec between the listing and the watch is still seen. A 2 s timer rescans as well, for a process the system
    will not let the watcher observe.
  - An OSC 7 that names another host. The source is the patched libghostty's `REMOTE_HOST` action, which reaches the
    applet through the surface protocol.
- Known gaps. A client that starts and exits between two scans is missed. `ssh` inside a local tmux, `kubectl exec`,
  `docker exec`, and any client not on the list look local. A shell that never reports OSC 7 gives only the process
  signal. A local `ssh` that ends leaves the tab marked, so one `git fetch` over ssh turns off clicks in that tab
  until it closes.
- A report that fails earlier in libghostty's OSC 7 handling gives neither a directory change nor the remote-host
  action. That covers an invalid or too long host name, a failed host lookup, and a missing host. The process signal
  still covers `ssh`.
- Residuals. A tab runs one check at a time, and a click while one runs says that a previous click is still being
  checked. On a dead network mount the one check parks a thread until the mount answers, and a stuck open is not
  cancelled, so a tab can park one thread and the tab clicks again only after it returns. The regression test failed
  first. The watcher names its root by PID alone, so a PID reused within the few
  milliseconds between the session's end and the watcher's stop could be read as the root.
- The clicked path's real path comes from the same reader as `uniterm open`'s scoped open, `DescriptorPath`.
- Residual. The router and the viewer open the verified path by name again after the check. A same-user process that
  renames or replaces the path in between changes what opens. ADR-14 accepts this as no isolation from the user's own
  processes.
- The terminal applet's host gained `applet(_:open:)`. The default says the host cannot open files. The window posts the
  same message when its set has no router, and otherwise routes through the router the app gave the set.
- No `test-cost` target exists in this repo. New and changed test classes ran in the package suite:
  `TerminalLinkTargetTests` 14 tests in 0.01 s, `TerminalLinkClickTests` 19 in 0.03 s, `RemoteClientWatcherTests` 9 in
  0.04 s, `ProcessInspectionTests` 5 in 0.003 s, and `TerminalConfigTests` gained 2. `TerminalSessionIntegrationTests`
  gained 2 and took 13.3 s in all, with the new ones at 0.26 s and 0.53 s. They start a real shell and drive libghostty
  with synthesized pointer events.
- The overlay sizes its label from what the cell needs to draw the text, through the cell's own size. The width of the
  bare string is a few points short, since the cell adds insets, and it cut the middle of a path that had room. A
  package test compares the label with the cell's required size and failed on the earlier code. The pill is capped at
  the pane width minus its margins, and a path is cut only past that.
- A debug-level log category, `terminal-link` under the `dev.uniterm.app` subsystem, records the pointer reports with
  position, modifier bits, and event type, the press, release, and modifier changes, each hover and open-URL action
  with its length and kind, and the applet's click decision. It never logs the text of a link, since program output is
  private. Debug level costs nothing in release and is not stored, so read it with `log stream --level debug`.
- libghostty drops a pointer move of under one pixel from its stored position, and that position starts at the origin.
  A hover or a click on a link needs a real move onto it. The UI tests therefore move the pointer from an empty area
  onto the path, with Command held, before they read the overlay or click.
- UI test classes this milestone adds: `TerminalLinkUITests`, 2 tests. The overlay screenshot was looked at and shows
  the whole path. The class passed 12 of 12 iterations in two runs of three. Earlier runs failed intermittently, once
  by the test's own typing, which mangled a quote and a backslash and is fixed. The other failures were a hover or
  click that never reached the link, in about half of the iterations of two runs. Their cause is not established, and
  they did not recur once the log was on. A potential flake is filed in `spec/flaky-tests.md`.

### M7: Launch Services approvals

Superseded in part by UTERM-036; see Decision Log.

**Status:** DONE

Amended 2026-11-17; see Decision Log. Moved from M2.

- Starts after UTERM-004 M6
- A sender other than Apple's openers goes to UTERM-004's pending indicator, named from its verified signing
  information, and can be allowed once or for the session
- A session grant binds to the sender's PID and PID version, so a reused PID never inherits it
- A batch from a sender that needs approval raises one prompt that names every file and covers the count
  confirmation
- A prompt for an unknown sender says the sender is unknown, lists every full path, and offers Allow once only
- A go-between such as `/usr/bin/open` gets Allow once only
- Nothing is remembered after the sender quits, and a sender that quits while its question waits withdraws it
- Nothing touches a path before its open is approved, so a pending, denied, withdrawn, or exited open never raises a
  macOS privacy prompt
- A Deny, a withdrawn question, and a pending indicator with no room each leave one coalesced message, and a flood of
  once-only events leaves room for every other requester's question
- The question says that a new window may open
- An approved open takes no focus and raises no existing window, and a cold-launch question lets the default window
  open

**As built:**

- Divergences and best guesses are in the Decision Log, 2026-11-17, M7 best guesses. The two that change a reader's
  expectation: every Apple-signed program that is not an opener gets Allow once only, and a Deny of an app lasts until
  that app exits.
- The authority has a new case, `needsApproval`, in place of the refusal. It says whether the answer can cover more
  than the one event. The coalesced message has a reason: busy, denied, withdrawn, or no local file.
- Each event is one operation in the pending indicator under a new requester. An app that can be allowed for its run
  asks under its PID and PID version, so its events share one row. A go-between and an unknown sender each ask under
  their own event, so a Deny of one never blocks the next.
- The question names the sender from its signing identifier, and the team or Apple. It lists every path with control
  and direction characters written out, and the count. The router's own question above 10 files is skipped, through the
  option M5 added to the route, which also turns focus off.
- The session grant lives in the coordinator, keyed on the PID and PID version. A process watcher ends it, and the
  watcher is injected, so tests end a sender by hand. The system's watcher reports exit and exec. An app is watched
  from its first question until it ends. A go-between and an unknown sender are not watched.
- No path is looked at before the answer. A test over the real coordinator, permission queue, router, and windows
  records the router's looks. A pending, denied, withdrawn, and already exited open each leave the record empty, and an
  allowed one records its path.
- A question waiting at cold launch does not count toward the coordinator's pending opens. The allowed open waits for
  restore in the coordinator's queue, as before.
- The UI test sends an open from the test runner, answers the question in the Pending Requests panel, and shows the
  pane open beside the first with the first still focused. A second test denies and shows the message. The runner is
  signed ad hoc with no team and no Apple anchor, and it is not an opener, so the app asks about it. Which process the
  event names as the sender for an NSWorkspace open from a sandboxed runner was not measured. The tests do not depend
  on it.
- `LaunchServicesOpenUITests`, 2 tests, is changed. Nobody has run them.
- The same process watcher ends the grant, so a sender that execs another program loses its grant. The process ID
  version is documented to change on exec, and the watch does not wait to find out.
- The system's process watcher reports a process that exited before the watch began. A package test spawns
  `/usr/bin/true`, waits for it, and then watches, so a sender that quits before its question is asked loses its
  question.
- Once-only events bound together under one requester bound, so a loop of them leaves room for every other requester.
  Apps that can be allowed for their run each bound alone, so many distinct live apps can still fill the rows. Each one
  needs its own signed process.
- Residuals for the user. A user's Deny can be folded into an earlier coalesced message within 30 seconds, so the
  Deny's own message may not post. A non-Apple interpreter, such as a Homebrew `python3`, can get a session grant that
  covers whatever script runs in it. The grant is bound to its PID and version and ends on exit or exec.
- A PID reused between the system's sender lookup and the watch's start is a residual. The window is the time between
  two calls in the same event handler. The grant still binds to the version, so a reused PID with a new version never
  matches.
- No `test-cost` target exists in this repo. New and changed test classes ran in under 1 s each in the package suite:
  `LaunchOpenApprovalTests` 16 tests in 0.94 s, `LaunchOpenCoordinatorTests` 8 in 0.56 s, `OpenAuthorityTests` 8 in
  0.001 s, `SenderWatcherTests` 2 in 0.19 s, and `PermissionRequestsTests` 3 in 0.002 s.

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
- 2026-11-16: M4 work-queue best guesses (work-queue best guess). Amended "How the path-reading power is granted",
  which said the user approves the power "with Allow once, session, and remembered approvals as for every other
  power". The decision never said what Allow once means for a read, and the command that reads is not known to the
  host until the applet's schema is. A read therefore needs the power to stand. Allow for This Run and a remembered
  approval make it stand, and Allow once does not, so a controller allowed once cannot read. The alternative, an
  extra question per read, would prompt once per slideshow member, which "How the path-reading power is granted"
  rejects. Also recorded:
  1. The walk runs off the main thread before the command is queued, not inside the authority check. A path may sit
     on a slow volume, and ADR-08 forbids an unbounded wait on the main thread. The authority and the scope are
     asked again as the command is delivered, and every opened descriptor's own real path is checked against the
     scope then, with the roots kept from the open. A grant that ends while the command waits therefore leaves no
     read, which is what the check asked for.
  2. The permission is named `path-read`, in format 2 at version 1, with a `directories` list. The meaning table holds
     it with no new format number, since an older build refuses an unknown kind in a descriptor and reads a policy
     file that holds one as newer.
  3. `/net` and `/home`, the automount points the older confined walk already refused by name, are protected places
     beside `/Volumes` and `/Network`. They are the network volumes the settled list names.
  4. Two approved path-reading scopes act as their union, for coverage and for the scope a run holds. A merge keeps
     one entry.
  5. The scope compares as the volume does. A scope directory is matched as written and with its links resolved, then
     the walk starts from the resolved directory. The protected places are also named with the home folder's links
     resolved.
  6. In-scope failures keep their causes, missing, not a file or folder, not allowed, and too many links. Every
     failure that an outside path could have returns one answer, and a command that names an outside path is
     refused with the same text as one from a caller with no power.
  7. Redaction applies to every caller of the pane list and the text viewer, not only a controller run, since an
     ordinary script holds no scope. The viewer reports its source through a small protocol, and a find's counts and
     anchors, a scroll's bounds, and a reload's failure code are hidden from a caller outside the scope. A scroll
     past the end of a hidden file answers as a fit and moves nothing, so a caller cannot measure the file.
  8. An exec driver brings no opens, so a command that names a path is refused for it.
  9. The fixture applet that reads paths is a debug fixture beside the slides, notes, and chart fixtures.
  10. A change in review fixed three things. Protected places match by case folding on every volume, since hiding more
      is always safe. An opened path remembers the resolved scope roots, so delivery re-checks with no disk reads,
      and a scope that changed while a command waited refuses it, the same as a revocation. The cost is that a grant
      that grew meanwhile also refuses, and the caller asks again. A run that declared the power and was allowed once
      gets its own refusal text, which says so, since it knows its own grant. Every other refusal stays one text.
- 2026-11-16: M5 work-queue best guesses (work-queue best guess). Amended "Where a routed pane goes", "Who may run
  `uniterm open`", and M5.
  1. "Where a routed pane goes" said that callers in no terminal session anchor to the focused pane of the most
     recently key window, "which is brought forward". It now says that bringing the window forward belongs to Launch
     Services senders, and that a `uniterm open` from a caller in no session anchors to the same pane, with no existing
     window raised. ADR-12 says a change the user did not choose never moves keyboard focus, and a program's open is
     not the user's act. The cost is that a command run from another terminal program opens its split in a window
     that stays behind. If wrong, the open brings the window forward as a Launch Services open does.
  2. The same entry adds a bullet that a pane or window a program's open makes takes no focus, and a matching M5
     check. A new window that holds only the routed pane is ordered in front without becoming key, and the app is not
     activated, since a window the user never sees would hide the open. A review found that the code raises such a
     window, and the first wording said no window was brought forward, so the text now says what the code does.
     If wrong, a new window opens behind the others.
  3. "Who may run `uniterm open`" said the reply never tells missing, unsupported, and denied apart. The plan listed
     "denied" in the uniform set. It now says the reply comes once the user allows the request, before any path is
     looked at, so success, missing, and unsupported look the same, and a request the user denies gets the refused
     status. A user's own Deny says nothing about a file, and a command that exits 0 after a Deny would mislead a
     script. Exit 0 therefore says only that the app took the request. If wrong, a Deny exits 0 and the text says so.
  4. The command's exit statuses: 0 for a taken request, 64 for a usage error, a path or count that does not fit, or a
     path that is not valid UTF-8, 66 for a deleted or unresolvable working directory, 69 for no app, 70 for a version
     mismatch, 74 for a connection lost before an answer, and 77 for a refused request. They follow the existing
     sysexits use.
  5. One wire change. Version 13 adds an open begin from the command and an open-done reply, and a refusal reuses the
     existing refusal and waiting messages. The begin has its own connection role, so a connection that began an open
     can make no call. The reader refuses what the command refuses, since a raw peer can skip the command. Nothing is
     cut or dropped to fit: at most 256 paths, 1024 bytes each, and 48 KiB together.
  6. A non-UTF-8 argument cannot be named in a string. The command reads one as a replacement character and refuses
     it, so a path with a real replacement character in its name cannot be opened by this command. That is rare, and
     a refusal is safe where a repaired name opens another file.
  7. The command does not have to be the bundle's own command. A program that sends the begin directly gets the same
     question and the same authority, since the authority is the terminal session and never the command. The
     `uniterm` command is not trusted more than any other program.
  8. A session grant is keyed on the session root and its generation, held in memory, and ended by removal of the
     root, by the close of its window, and by a generation that no longer matches the registry. A denial is kept for
     the session under the terminal's own requester, so a program in a loop is not asked again until the user chooses
     Ask Again or the pane closes. A command in no session keeps its denial under its connection, so the next command
     asks again, as the settled decision says.
  9. The question names the pane by its applet's title and says it covers every program in the session, as the OSC 52
     approval says. Control, format, and separator characters in a path are written out as code points, and nothing is
     cut, so the question lists every path in full.
  10. A program's open waits for layout restore in the Launch Services coordinator's queue. It reuses the settled rule
      that an open arriving during restore waits, and it keeps the layout from opening a default window beside it.
  11. The router's look at a path is an injected reader with the system's own as the default. The route has an option
      that skips its own batch question when an approval already named the count, and turns focus off. Both are
      reusable for Launch Services approvals.
  12. `RoutedOpener.openWithChoice`, File > Open, and Apple's openers are unchanged.
  13. Package test classes added or changed ran in under 1 s each: `ScriptOpenTests` 12 tests in about 0.2 s,
      `ScriptOpenRunTests` 6 in 0.63 s, `ScriptOpenWindowTests` 5 in 0.49 s, `ScriptOpenCommandTests` 4 in 0.001 s,
      and `ScriptCodecTests` 28 in 0.03 s. `ScriptOpenUITests` is new and was not run.
  14. A session allow leaves the session's other waiting questions pending. The row answered is the only one decided,
      and each other row is checked again, for the connection, the peer, and the session, when the user answers it. A
      second row for the same session still offers the session answer, which only stores the grant again. If wrong,
      the session answer decides every waiting row of that session, as the clipboard session answer does for a row.
  15. A command bound to a session whose pane or applet can no longer be named is asked about as a command outside
      every session. The question could not tell the user which session a grant would cover, so the wording, the
      once-only flag, and the grant all follow one condition: a named pane. If wrong, the question names no pane and
      offers the session answer.
- 2026-11-16: ADR candidate (cuts across the system): a caller learns nothing about a user's file outside its read
  scope from any reply, event, or listing, and every applet that shows a user's file must keep it. Undecided. Found
  in M4.
- 2026-11-17: M6 work-queue best guesses (work-queue best guess). Amended "Who may open by terminal click", "Start
  directory and current directory", the Risks entry on libghostty, and M6.
  1. The hover shows a `file:` link as its decoded path, and the click is bound to the link text. A link with a query,
     a fragment, or credentials is refused. So is any text with a control, format, separator, or unassigned character.
     The settled text said the overlay shows the target and was silent on text that cannot be shown as it is. A path
     that shows as another path is the case the shown target exists to stop. The overlay does not call the status
     bar's `sanitized`, since that collapses runs of spaces, and a path with a double space would show as another file.
     If wrong, such links open.
  2. The remote marker covers one terminal tab and ends with its session, where the settled text said the pane. Each
     tab is its own session with its own tty and process tree, so one tab's `ssh` does not need to turn off another's
     clicks. A second tab keeps working. If wrong, one tab's marker covers the pane.
  3. Ghostty patch 003 reports a non-local OSC 7 as a new action carrying the host, and removes libghostty's join of
     clicked text to its working directory with the access check. The hidden state flow the project rules name was
     libghostty resolving a clicked relative path against its own tracked directory. Plan approval confirmed removing
     it.
     The patch is five files and kept minimal. The alternative of a `host` field on the existing working-directory
     action would change a message type that the library also uses for local reports.
  4. libghostty's open-URL action is always taken, so its fallback opener never runs. `link-url`, `link-osc8`, and
     `link-previews` are written explicitly and accept `true` only. A hover for plain text needs previews on.
  5. A click whose text differs from the last hover is refused with a message. The settled text said it opens only on
     equality and did not say what else happens. A silent no-op after a click would be a failure with no feedback.
  6. A path that starts with `~` or `$` counts as relative and is refused, as the plan guessed. "Start directory and
     current directory" says the refusal posts a status message now. It said clicking `notes.txt` does nothing.
  7. The verification is an `lstat`, then an open with the flags the plan named, then `F_GETPATH`, with one
     normalization for both sides. The prefixes are `/tmp`, `/var`, and `/etc`, which are links into `/private`. The
     settled text called them firmlinks, which was a mistake of fact. They are ordinary links, and the text now says so.
     Real firmlinks keep their name in the real path, so they need no mapping. The
     `lstat` is the one extra look at the path before the open, so a FIFO or a device is never opened. A swap between
     the two is caught by comparing device and inode.
  8. The scan watches every process in the session's tree, and a 2 s timer rescans. The plan named kqueue events with a
     rescan on each. The system may refuse to let an unprivileged process watch the root, a setuid `login`, and then the
     shell's fork would go unseen. The timer costs one tree listing per 2 s per tab. If wrong, the timer goes. A client
     below an unwatchable process is then found only on a later event of a watched sibling.
  9. A click takes focus and opens beside the clicked pane, with the router's default options. A click is the user's
     act, as File > Open is.
  10. The router and the viewer open the path again after the check. The check cannot hand the viewer a descriptor,
      since the source-taking entry points take a path. A same-user rename in between changes what opens. This is the
      residual the plan named. It is accepted under ADR-14.
  11. The REPL pane gets the three new events and ignores them. A click there did nothing before either, since
      libghostty's own opener refuses these links.
  12. A review found a stale preview. A tab hidden while the pointer left its link showed that link again when
      selected. A hidden tab's hover is now forgotten, so the next hover sets it and a click before that is refused.
- 2026-11-17: M7 work-queue best guesses (work-queue best guess). Amended "Opens that arrive through Launch Services"
  and M7. The section said every other sender is refused until UTERM-004 M6 lands, then goes to the pending indicator.
  It said a go-between and a sender that cannot be identified get Allow once only. It said nothing on what a Deny or a
  sender that quits does, or on a cold launch with a question waiting. M7 listed no check for them.
  1. Every Apple-anchored sender that is not an opener gets Allow once only, whatever its identifier. The text named
     `/usr/bin/open`, a Launch Services helper, `osascript`, and `python3`. No helper identifier was measured, and a
     list of names would be a guess about who counts as a go-between. A sender that was identified but has no signing
     identifier is treated as unidentified, since the question cannot name it. A third-party signed app, with or
     without a team, gets Allow once or Allow Until This App Quits. If wrong, an Apple-signed app that the user drives
     is asked on every open.
  2. A session grant binds to the PID and PID version, lives in memory, and ends when the sender exits or starts
     another executable. The text said until it quits. The kernel gives a process another version when it starts
     another executable, so the grant could not match it anyway, and the watch ends it at once. If wrong, the watch
     listens for exit only.
  3. A Deny of an app lasts until it ends, so a loop that opens again is refused at once with the message, and it
     asks again after a new run. A Deny of a go-between or an unknown sender is not remembered, since no later event can
     be tied to it. If wrong, a Deny of one `open -a` blocks every later one until Ask Again.
  4. A sender that quits while its question waits withdraws the question, and nothing opens. Only an app that can be
     allowed for its run is watched. A go-between exits as soon as it has sent the event, and withdrawing on that would
     refuse every `open -a`. If wrong, a once-only sender's question is withdrawn too, and `open -a` never opens.
  5. A refusal posts through the coalescer that M2 built, one message per 30 seconds, with a reason: no room, a
     Deny, a sender that quit, or no local file. An event whose items are all non-file URLs is refused with the last
     reason, so it neither asks nor opens. Mixed events ask about the file paths and say how many items will not open.
     If wrong, the unusual events post their own messages without a bound.
  6. A question waiting at cold launch does not count as a pending open, so the layout opens its default window. The
     allowed open then waits for restore. The question may sit in the indicator of a window that opened for it. If
     wrong, a cold-launch open from another program opens no window until it is answered, and cannot be answered.
  7. An approved open anchors to the focused pane of the most recently key window, takes no focus, and raises no
     existing window, through the option and the coordinator path M5 built. A new window holding only the routed pane
     is ordered front without becoming key.
  8. The question's wording is the user-facing text this milestone adds: the row names the sender as its signing
     identifier and the team, or Apple, or no team. The session answer is titled "Allow Until This App Quits". Its
     detail says the same, and says it covers everything that app sends. If wrong, only the text changes.
  9. Package test classes added or changed ran in under 1 s each: `LaunchOpenApprovalTests` 16 tests in 0.94 s,
     `LaunchOpenCoordinatorTests` 8 in 0.56 s, and `OpenAuthorityTests` 8 in 0.001 s. `LaunchServicesOpenUITests` is
     changed and was not run.
  10. A review found that each once-only event is its own requester, so 64 of them from an `open -a` loop filled every
      row and refused OSC 52, scripts, and controllers as busy. Every open event's requester now counts against one
      bound, `maxRowsPerRequester`, as one requester would. Past it the new event is busy, with the coalesced message,
      and the waiting rows stay. The regression test failed first, with 64 rows and a busy clipboard request. If wrong,
      a flood of events can fill the indicator.
  11. ADR-14 says opening a window is a power of its own. An approved open can make a new window that holds only the
      routed pane, and the question said only "each in a new pane". The question now says a new window opens when a
      batch or a lack of room calls for one, so the one approval names it. The session grant covers it too, and its
      text says it covers everything the app sends. If wrong, a window opens under an approval that never said so.
  12. A review doubted that the system's watcher reports a process that already exited. A package test with a real,
      reaped process shows it does, so no liveness check was added. The test pins the behavior.
- 2026-11-17: Row review fixes (work-queue best guess). Amended "Where a routed pane goes", "Who may run `uniterm
  open`", M4, M5, M6, Dependencies, and three Risks. ADR-14, accepted during this run, supersedes ADR-09 and restates
  every rule of it.
  1. "Where a routed pane goes" said Finder, the Dock, and other Launch Services senders anchor to the focused pane of
     the most recently key window, "which is brought forward", and that a routed split raises no existing window.
     Since M7, only Apple's openers bring the window forward, and an approved sender that is not an opener raises
     nothing and takes no focus. The code did this already, in the coordinator. The anchor bullet now says so. The M5
     entry above says bringing the window forward "belongs to Launch Services senders", which was true of the opener
     and false of an approved sender. That line stays as it was written. This entry corrects it. The focus bullet named
     only File > Open and Apple's openers as the user's act that takes focus. It now names a terminal click too, per
     M6. If wrong, an approved sender's open brings the window forward.
  2. "Who may run `uniterm open`" said nothing on the question's wording, and the M5 question said only "each in a new
     pane". An approved batch, or an open with no room, opens a new window through the same placement, and opening a
     window is a power of its own under ADR-14. The question now says "A new window opens when a batch or a lack of
     room calls for one", as M7's does. The decision gained a bullet, and M5 a check. If wrong, a window opens under an
     approval that never said so.
  3. Commands outside any terminal session each ask under a fresh connection. A loop of `uniterm open` could hold up
     to the listener's 32 slots and 32 rows while the questions waited, and no script could connect. This was traced
     and confirmed by a test that failed first, with 20 rows for 20 commands. They now ask under a requester that
     shares one bound of `maxRowsPerRequester` rows, as M7 did for events. Past it the command is refused at once with
     exit status 77, which frees its slot. The decision gained a bullet and M5 a check. Commands in a session keep
     their own requester. If wrong, a flood can fill the listener.
  4. A click's check opened a program-chosen path on a GCD thread with no bound, so on a dead network mount each click
     parked a thread. A tab now runs one check at a time, and a click while one runs is refused with a status message
     that says a previous click is still being checked. M6 gained a check, and its residual no longer says "no bound".
     The regression test failed first. The bound is per tab, not per pane, since each tab is its own session. If
     wrong, another bound, such as one per pane, changes only the counter.
  5. M4's walk had the same exposure. Calls of one connection are not serialized, so a script can pipeline them, and
     each walk runs a blocking open on the concurrency pool. A connection now has at most 4 walks running, and a walk
     past that is refused with the uniform answer for an outside path, so it tells nothing. The bound is 4, not 1, so a
     script that reads from a few fibers still works. A test with an injected blocking opener failed first, with two
     walks running at once. The members of a folder source are opened by the applet while it runs the delivered
     command, and they are not counted. If wrong, the bound is an init parameter and one constant.
  6. The descriptor's real path was read in two places, the scoped open and the click check, each with its own buffer
     and decode. One reader, `DescriptorPath` in the source access module, now serves both. The terminal applet gained
     a dependency on that module. The two checks keep their meanings, containment in a scope and equality with a shown
     string. The click check's `MAXPATHLEN` buffer became `PATH_MAX` plus one, as the scoped open's was. The two are the
     same size on this system.
  7. The Dependencies line said "Until it lands, M2 refuses other senders". UTERM-004 M6 has landed, and M7 built the
     approvals. The line says so. The Risk that M2's sender measurement reopens the Launch Services decision is
     resolved by M8's record. The Risk that third-party launchers are refused and `uniterm open` cannot ship until
     UTERM-004 M6 and UTERM-003 M3 land is resolved, since both are built. The Risk "No viewer applet exists in code
     yet" was false. The viewers exist and declare types. It now says that no viewer has a path-reading controller
     command yet, so M4 is proven on fixtures. Updated is 2026-11-17.
  8. Citations of ADR-09 in the settled text, the M4 check, and the M6 As built and its best-guess residual now cite
     ADR-14. ADR-14 restates every ADR-09 rule, and a citation of a superseded ADR points at a stale record. The
     References keep ADR-09, marked as superseded. Older Decision Log entries keep their citations, since they were
     true when written. The M6 best-guess line on the same-user residual is the one exception, which the review named.
  9. Test changes. `PathSpy` moved into the shared window test fixture. The M5 and M7 placement tests each say which
     authority they isolate. `testTheAsyncCheckAnswersLikeTheSyncOne` is retired. `testAClickOpensExactlyTheShownFile`
     and `testAMissingPathSaysSo` already run the real async check through the applet and prove both answers.
- 2026-11-17: Implemented. M4 to M7 finished in the work-queue run recorded in
  `spec/reports/20261116-uterm-015-m4-m7-cross-applet-file-opening.md`, and every milestone is DONE.
- 2026-11-17: Correction of fact, from the final review. The row-fix entry re-pointed every ADR-09 citation to
  ADR-14, and one of them was wrong. ADR-14 did not exist when UTERM-006 settled the path-reading power. Motivation
  read: "UTERM-006 also settled that asking an applet to read a path is a power of its own under ADR-14, apart from
  pane control. ADR-14 lists no such power, and UTERM-005, UTERM-006, UTERM-007, and UTERM-009 each need the same
  one. One definition keeps them from diverging." That historical sentence cites ADR-09 again, with "(superseded by ADR-14)". It is the one exception to item 8
  above. A stray blank line before the "Implemented" entry was also removed.
- 2026-11-17: Correction of fact. Dependencies read: "- UTERM-004 M4: M1's check that a routed split never joins a
  group a controller owns. Until it lands, the check runs against a fixture group". UTERM-004 M4 has landed, and
  `testARoutedSplitNeverJoinsAControllerGroup` runs against a real controller-owned group from `openPane` with an
  owner. The line now says so.
- 2026-11-20: Superseded in part by UTERM-036. A program's approved open lands as a Launch Services open does. The
  anchor's window comes forward, the routed pane takes focus, and a new window becomes key. This replaces the bullet that
  a pane or window a program's open makes takes no focus, and the anchor bullet's lines that such an open raises no
  window. It also replaces the M5 and M7 checks that an approved open takes no focus and raises no existing window.
- 2026-11-26: Superseded in part by UTERM-065. An exec driver that holds UTERM-065's per-run read grant brings opens,
  and names paths in its scope. This replaces the 2026-11-16 best guess 8, that an exec driver brings no opens, for a
  driver that holds the grant.

## References

- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): restored state is inert
- [ADR-06](../adr/ADR-06-layout-file-versioning-and-schema-ownership.md): each applet owns its payload
- [ADR-09](../adr/ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): control authority,
  separate powers, and explicit scope (superseded by ADR-14)
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): control authority, separate powers, explicit
  scope, and opening a window as a power of its own. It restates every ADR-09 rule
