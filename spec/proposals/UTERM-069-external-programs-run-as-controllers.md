# UTERM-069: External Programs Run as Controllers with an External Source

**Status:** draft
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- UTERM-004: process-ancestry binding, the session root, and Pending Requests, which this proposal keeps. Give Group is
  never offered to an external program, per "How the user hands an external program a pane"
- UTERM-021: declared permissions, which an external program must carry
- UTERM-015: routed placement for an open with no origin pane, which an external program's first pane follows
- UTERM-036: a program's opens take focus as the user's do
- UTERM-063: the script wire is at version 0, so the declaration message for direct clients lands in place after
  UTERM-063 M2
- UTERM-054: the tab scope that narrows a tab source to its own tab and the tabs it opened

## Impacts

- UTERM-004 — "How uniterm knows which pane a program runs in": "An unbound caller has no pane access. The user can
  explicitly grant that connection a named source pane in one window." The explicit grant, and the 2026-11-10 best
  guess that binds a grant to the newest session in the pane, are replaced. An unbound program becomes an external
  program. UTERM-004 is implemented, so its text stays, and it gains a "Superseded in part by UTERM-069" marker when
  this proposal is accepted.
- UTERM-054 — "A program's tab scope in a terminal pane": "The source tab comes from the tab whose session the
  binding's root belongs to." That holds for a tab source. An external program has no source tab, so its tab scope is
  only the tabs it opened.
- UTERM-064 — "The own-tab alias for a caller with no source tab" rests on the source kinds settled here. A tab source
  names its tab, a pane source names its pane, and an external program has no place of its own to name.
- ADR-14 — P2 ties a run's windows to its source window. An external program has none. See the open question "What an
  external program's window is".

## Summary

Every program has a source, and the source is one of three kinds: a tab, a pane, or external. A program uniterm cannot
trace to a tab is external. It runs as a controller with an external source: it declares its permissions, the user
approves it on the controller sheet, and it starts with no reach. Grant Access, its pane picker, and the binding to a
pane's newest shell go away.

## Motivation

Today a program uniterm cannot trace to a tab waits in Pending Requests until the user chooses Grant Access and picks a
pane. The grant does not bind the program to that pane. It binds it to one shell running there, the newest one, which
the user never chooses (`ScriptHost.sessionRoot`, `ScriptHost.swift:1058-1062`). The grant then ends when that shell
exits, even while the pane and its other tabs stay open. Meanwhile the program reaches every tab in the pane, because
authority is checked per pane (`WindowScripting.swift:657-663`). A program started in a tab reaches every tab of its
pane today for the same reason. UTERM-054's tab scope narrows that for tab sources, and this proposal does not.

A granted program is also indistinguishable from one started in that pane. `caller(for:)` returns the same window and
pane for both (`ScriptHost.swift:770-781`), and nothing in the pane's badge or markers tells them apart. So an outside
program's actions read as the user's own shell's. That breaks the trust the source binding exists to give.

The grant came from a 2026-11-02 autonomous review of UTERM-004, as a fallback for callers whose provenance cannot be
established. The newest-shell binding was a best guess during UTERM-004 M1. The user chose neither. The sheet also
offers panes without remote control, where a granted program can do nothing (`PendingRequestsWindowController.swift:
543-556`).

A program that loses its link to its tab is in the same position. uniterm checks ancestry on every call, and a program
whose parent exited is re-parented to launchd. uniterm then discards its binding (`ScriptHost.swift:693-700`) and keeps
no record of the tab it came from. That covers a daemon that double-forks, a `nohup` job whose shell ended, and a
program inside tmux, whose server detaches.

## Design Decisions (Settled)

### A source is a tab, a pane, or external

Decision: every program's source is one of three kinds.

- A tab source: a script or a controller started in a uniterm terminal tab, bound by process ancestry to that tab's
  shell.
- A pane source: an exec driver, which the user attaches to a pane.
- An external source: any program uniterm cannot trace to a tab. That includes a program that loses its link to its
  tab.

The external source is a record the script host owns. It has its own lifecycle and nothing in the pane tree. It is not
a pane, a tab, or an applet with no view. The user chose this on 2026-11-26.

Rationale: a pane or a tab must obey every rule panes and tabs obey: normalization and stable identities, the saved
layout and restore, focus, the palette, Reopen, listings, and applet lifecycle events. An invisible one needs an
exception in each of those places. An applet contract is about showing content and taking the user's input, and an
external source has neither. A record answers what a source has to answer: who is acting, in which window, from where
its reach starts, whether it is switched on, and when it ends.

### An external program's first pane opens where an outside open lands

Decision: an external program's first pane opens where any open with no origin pane lands under UTERM-015: beside the
focused pane of the most recently key window, or in a new window when none exists, there is no room, or a sheet is up.
The window its first pane lands in becomes its one window. The user chose this on 2026-11-26.

Rationale: an external program is an open with no origin, and this is uniterm's standing answer for where such an
open lands. UTERM-015 already anchors a `uniterm open` from a caller in no terminal session there. UTERM-015's routed
pane is new, disconnected, and joins no controller's group, so the precedent covers placement only. Here the pane is
the program's own, and it gains that pane, not the focused pane beside it. Always opening a new window would isolate it more cleanly, but each external program would
then make a window, which nothing else in uniterm does.

### An external program is a controller

Decision: an external program is a controller whose source is external. It declares its permissions, and strict mode
refuses one that declares nothing. Any program may declare. The user chose this on 2026-11-26. Amended 2026-11-26; see
Decision Log.

- A program run through uniterm's command, `uniterm run` or `uniterm controller run`, declares as it does in a tab.
  uniterm verifies it the same way: the command's signature, and the app's own snapshot of the file or package.
- A program that talks to the socket directly sends one declaration message first, with its name and the permissions
  it wants. This is a change to the script wire. Today such a program sends a plain begin and is admitted without being
  asked (`ScriptUndeclared.swift:145-160`).
- The user approves it on the existing controller sheet. Trust This Version is offered only for code uniterm can
  verify. A run through uniterm's command is verifiable. An interpreter running a script, such as `python3 good.py`,
  never is: it is offered Allow Once, Allow for This Run, and Deny, and the sheet shows the script it claims to run,
  read from the process's arguments and marked as claimed. How uniterm tells verifiable code from an interpreter is
  open. See "What counts as code uniterm can verify".

Rationale: everything trust needs already exists for controllers: a declaration, an identity check, the sheet, and
remembered trust per version. An external program differs only in where it starts. Requiring a declaration keeps
strict mode meaningful. uniterm reads every caller's audit token and the executable's code identity
(`ControllerIdentity.swift:253`), so it can verify compiled code. It cannot verify which script an interpreter runs:
the arguments are only a claim, the file can change, and the script can load other code. ADR-14 P9 says "the identity
of a shared interpreter" is insufficient proof, so such a program never gets remembered trust.

### Origin is tracked and never grants anything

Decision: uniterm records each program's origin, the most specific place known when it started: a tab, else a pane,
else a window, else outside uniterm. A program that loses its link keeps "started in tab X" as its origin. The origin is
shown to the user, on the sheet and in the badge's details, and is never read to decide anything. The source kind
decides authority and reach. The user chose this on 2026-11-26. (addition)

Rationale: the user wants to keep track of where things start, as attribution, apart from what decides trust. Keeping
the two apart stops a record of where a program came from from becoming implicit inheritance of that place's rights.

### The sheet asks only about the program, its permissions, and how long

Decision: the approval sheet answers three things: is this the right program, are these permissions reasonable, and
for how long. It shows the program's name, path, process ID, signature or version, and one origin line, such as
"Started outside uniterm" or "Started in tab 'build', no longer attached". A tab title in the origin line is text a
program can set, so the sheet quotes it and bounds its length. It has no window, pane, or tab picker. An external
program starts with no reach: it reaches the panes it opens. Each pane stays behind its own remote-control switch. The
user chose this on 2026-11-26. Amended 2026-11-26; see Decision Log.

Rationale: the pane picker exists only because the program borrowed a tab. Without the borrowing, nothing on the sheet
needs a place. There is no way to hand it a pane it did not open. See "How the user hands an external program a
pane".

### Grant Access is removed

Decision: Grant Access, its pane picker, the binding of a grant to a pane's newest shell, and a granted program acting
as if it had started in that pane are removed. A program that would have waited for a grant is an external program.
The user chose this on 2026-11-26.

Rationale: the grant made an outside program's actions indistinguishable from the user's own shell's, reached every tab
of the pane, and ended with a shell the user never chose. The external source gives the same programs a way in without
any of that.

### How the user hands an external program a pane

Original question: Grant Access set an outside program's source pane, and ADR-14 P2 makes the source pane a target: "A run's targets are
the panes it opened, plus the source pane it acts for." So Grant Access also let the program drive that pane, and every
tab in it. Removing it removes that. Give Group cannot replace it: it hands over only a restored group with no owner,
and offers it only to programs already acting in that window (`MainWindowController+Layout.swift:108-123`).

- A. A "Give to <program>" action on a pane's control badge hands that one pane to a running external program as a
  target, with no change to its source. It still needs remote control on. (addition)
- B. Give Group can give any pane or group the user picks to a running program. It changes what Give Group means.
- C. No path. An external program only acts on panes it opens. To drive an existing pane, the user runs the program
  from a tab in it.

Decision: there is no way to hand an external program a pane it did not open. A program that needs a pane declares
permission to open panes, and opens its own. To drive a pane the user already has, the user runs the program from a tab
in that pane. The user chose this on 2026-11-26.

Rationale: an external program cannot see the user's panes, so it cannot ask for a particular one, and a request for a
kind of pane brings back a picker. Handing panes over ahead of time asks the user to guess what a program needs, and
any extra pane widens its reach for nothing. No program is known to need one of the user's existing panes from outside
a tab.

## Design Decisions (Open)

### What an external program's window is

ADR-14 P2 says "Its windows are the source window, which holds that source pane, plus the windows the run itself
opened. A run never gains a pane or a window by position, nesting, or a later user move." P4 says "A window a run
opened holds only panes that run opened." An external program has no source window, and its first pane may land in a
window the user opened.

Whatever this settles must also say when an external source ends, and what happens when its window closes. ADR-14 P5
ends a grant when its source window closes, and an external program has none.

- A. The window is only where its panes sit. The program reaches its own panes in it and nothing else there, so it
  gains no window by position. Its later opens land in that window.
- B. The window is the program's scope, as a source window is. ADR-14 P2 then needs an amendment, since the program did
  not open that window.
- C. An external program's first pane always opens in a new window, which it then opened under P2. This reverses the
  settled placement.

### How an external program opens its first pane

`openPane` requires a `beside` target (`ScriptProtocol.swift:308-310`), and an external program has no pane to name. A
first open needs a form with no anchor, which lands by the settled placement. This is a change to the script wire.

- A. `open-pane` takes no anchor for a caller with no source, and lands by the settled placement.
- B. A separate call opens a program's first pane.

### What a program that loses its link keeps

A program started in a tab was approved as a tab-source run. When it loses its link, it becomes external. Today it
then has no caller at all, and every call is refused (`ScriptHost.swift:783-789`), even though its groups remain. It
may already own panes in several windows. A program can also choose to lose its link, by double-forking.

- A. Its approval ends with the link, and it asks again as an external program. Its groups are released.
- B. Its run approval carries over, and its source becomes external with the reach of an external program. Which
  window becomes its window, and whether it keeps groups in other windows, follows from "What an external program's
  window is".

### Whether opening a new window is its own permission

ADR-14 P8 keeps powers separate. Under the settled placement, an external program's first open can make a new window
when no window exists or there is no room.

- A. Opening a pane covers the window it lands in, wherever it lands.
- B. An external program declares a separate window power to be allowed a new window.

### Whether a direct client in a tab declares

Today a program that talks to the socket directly and starts in a tab sends a plain begin and is admitted without
being asked (`ScriptUndeclared.swift:145-160`). Strict mode covers only runs through uniterm's command. Under this
proposal the same program started outside uniterm must declare, so the one in a tab gets more power with less review.

- A. Every direct client declares, wherever it starts. Strict mode refuses one that declares nothing.
- B. Only an external direct client declares. A direct client in a tab keeps today's admission.

### What counts as code uniterm can verify

A direct client run as `node client.js` reads to uniterm as `node`, a signed compiled executable. Its code hash says
nothing about the script. If the sheet offered it Trust This Version, any node script sending the same declaration
would get standing powers with no prompt. ADR-14 P9 forbids that. The same holds for bun, deno, a custom interpreter, and
any program that loads plugins. No code today recognizes an interpreter.

- A. Only runs through uniterm's command, including a native controller package's entry, are verifiable. A direct
  client never gets Trust This Version.
- B. A direct client gets Trust This Version only when its executable is signed by a team the user names on the sheet.
- C. A list of known interpreters is excluded, and every other compiled direct client may be trusted. A missing
  interpreter fails open.

### Whether remembered trust covers a run started outside a tab

`proceed` admits a run that a remembered policy covers, wherever the run started (`ScriptControllers.swift:262-272`).
Today Grant Access still gates a trusted controller started outside a tab. Without it, any process of the same user,
from cron, ssh, or launchd, can run a trusted controller and get its standing powers with no prompt.

- A. Remembered trust covers tab-source runs only. An external run of a trusted version still asks once per run.
- B. Remembered trust covers external runs too, and the risk is accepted.
- C. A trusted version records whether it may run as external, and the sheet asks that once.

### Whether an external program's opens take focus

Under UTERM-036 a program's open with no anchor activates uniterm, and the new pane takes focus. A background external
program could move the user's typing into a pane it controls.

- A. An external program's opens take focus as the user's do, per UTERM-036.
- B. An external program's opens never activate uniterm or take focus.

### Whether a broken terminal identity is accepted

UTERM-004 mitigates a broken terminal identity patch with the explicit grant path. Without it, every program in every
tab becomes external, and scripts that act on their own pane are refused.

- A. Accepted, as for tmux: programs still run as external and open their own panes.
- B. A mitigation: the app refuses to start programs from tabs while the identity patch is broken, and says why.

## Risks

- **Programs that rely on Grant Access stop working** — likelihood: medium, impact: low.
  A program started outside uniterm that makes calls without declaring permissions is refused under strict mode.
  Accepted: the only such programs are the user's own, and each can declare, through uniterm's command or the
  declaration message.
- **Direct clients built before the declaration message** — likelihood: high, impact: low.
  An existing direct client sends a plain begin and no declaration. Under the new app it is refused at its first call.
  Mitigation: the refusal names the declaration message, under UTERM-063's rule that a stale program is refused by
  name, never reinterpreted. A new client against an older app is refused at the unknown message, the same way.
- **Remembered trust admits a run started from anywhere** — likelihood: medium, impact: high.
  Today a trusted controller started outside a tab still needs Grant Access before it acts. Without it, any process of
  the same user, from cron, ssh, or launchd, can run a trusted controller and get its standing powers with no prompt
  (`ScriptControllers.swift:262-272`). Settled by the open question "Whether remembered trust covers a run started
  outside a tab".
- **Programs in tmux or screen are always external** — likelihood: high, impact: medium.
  Their server detaches, so a program inside never traces to a tab, and each run goes through the sheet. Accepted: the
  sheet's origin line says so, and the program opens its own panes. It cannot act on the tab it visibly runs in.
- **A terminal identity failure makes every program external** — likelihood: low, impact: high.
  UTERM-004 mitigates a broken terminal identity patch with the explicit grant path. Without it, every program in every
  tab becomes external, and scripts that act on their own pane are refused. Settled by the open question "Whether a
  broken terminal identity is accepted".
- **An outside open takes keyboard focus** — likelihood: medium, impact: medium.
  Under UTERM-036 a program's open with no anchor activates uniterm, and the new pane takes focus. A background external
  program could move the user's typing into a pane it controls. Settled by the open question "Whether an external
  program's opens take focus".
- **The design rests on in-flight proposals** — likelihood: medium, impact: medium.
  UTERM-064 is in review, UTERM-054 supplies the tab scope a tab source implies, and UTERM-066 changes exec driver
  identity, which a pane source relies on. Mitigation: each is a dependency or an impact here, and a change to them
  reopens the matching decision.
- **An external program's first pane lands in the user's working window** — likelihood: high, impact: low.
  Mitigation: it lands where any outside open lands, it reaches only that pane, and the pane's badge names it as
  external.
- **The external source becomes a cross-cutting authority kind** — likelihood: high, impact: medium.
  Every check that asks for a program's source answers by kind, and a missed case could treat an external program as a
  tab source. Mitigation: the source is one type with three kinds, so each check must handle all three to compile.

## Milestones

### M1: Source kinds and the external source

**Status:** NOT STARTED

- A program's source is a tab, a pane, or external. A REPL helper is a tab source for its REPL pane's one tab
- A program that uniterm cannot trace to a tab, and one whose ancestry breaks mid-run, is external
- An external program makes no effect before the user approves it
- An external program whose origin is tab X is refused on tab X, and pane, tab, and capture calls are each tested for
  every kind
- An external program reaches only the panes it opened, each behind its remote-control switch, and none of the tabs it
  did not open. Give Group is never offered to it
- An external program's first pane opens where an open with no origin pane lands, and that window becomes its window
- An external program's panes and badge read "External" with its name, never as the user's shell
- Each program's origin is recorded and shown, and no authority check reads it
- `uniterm open`, `uniterm ask`, and Launch Services opens from outside uniterm behave as before

### M2: Approval on the controller sheet, and Grant Access removed

**Status:** NOT STARTED

- An external program that declares nothing is refused under strict mode, with text that says to declare its
  permissions
- An external program is approved on the controller sheet with its name, path, process ID, signature or version, and
  origin line, and no place picker
- A direct client declares with the declaration message, and one that sends a plain begin is refused by name in strict
  mode
- The declaration message uses a new message tag, never a reused one, and a decoder built without that tag refuses it
  by name with text that says to update uniterm
- The sheet quotes and bounds an interpreter's claimed script and its arguments, as it does a tab title
- A `uniterm controller run` of an untrusted version started with no tab session, such as from cron, reaches the sheet
  as external. A trusted version follows the answer to "Whether remembered trust covers a run started outside a tab"
- An undeclared run through uniterm's command from outside uniterm in unsafe mode gets the undeclared review, as in a tab
- An interpreter running a script is never offered Trust This Version, by the rule "What counts as code uniterm can
  verify" settles, and the sheet marks its script as claimed
- Grant Access, its pane picker, and the binding to a pane's newest session are gone, and their tests are replaced by
  tests of the external source
- The refusal that tells an unbound program to ask for Grant Access is replaced, and Pending Requests keeps its other
  rows
- Strict mode's setting and its refusal text describe programs, not only script files
- UTERM-004 and UTERM-054 record the change

## Decision Log

- 2026-11-26: Drafted from the UTERM-064 review. The user chose three source kinds, an external source as a record with
  its own lifecycle, a first pane placed as an outside open, external programs as declared controllers, origin as
  display-only metadata, a sheet with no place picker, and removing Grant Access.
- 2026-11-26: Critique pass. Two settled decisions rested on wrong claims. Direct socket clients could not declare, and
  Give Group cannot hand over an existing pane. The user chose that any program may declare: a direct client sends a
  declaration message, and Trust This Version needs code uniterm can verify, so an interpreter's script is shown as
  claimed and gets once or this-run approval only. This settled the open question on Trust This Version. (addition: a
  declaration message on the script wire, a code-identity trust path for direct clients, and reading process arguments) Reach is now
  only what the program opens, and handing it a pane is an open question. Added open questions on the first pane's
  wire form and on what a program that loses its link keeps, and risks on stale direct clients, remembered trust from
  anywhere, tmux, terminal identity failure, focus, and in-flight proposals. Routed REPL helpers, unchanged opens,
  strict mode's wording, and the refusal text to milestone checks.
- 2026-11-26: How the user hands an external program a pane: there is no way. A program that needs a pane declares
  permission to open panes and opens its own. The user chose this. Added the open question of whether a direct client
  started in a tab must declare too.
- 2026-11-26: Re-check pass. Give Group is never offered to an external program, which the "no way to hand a pane"
  decision implies, and M1 no longer cites it. Added open questions on what counts as verifiable code, remembered trust
  for runs started outside a tab, focus for external opens, and a broken terminal identity, which risks had deferred
  to questions that did not exist. Routed checks on refusal text, quoting claimed scripts, cron runs, and unsafe mode.
- 2026-11-26: Closing re-check. The declaration decision no longer settles that a compiled executable is verifiable,
  which let an interpreter like `node` be trusted. It keeps the user's rule that an interpreter running a script is
  never trusted per version, and leaves the detection rule to its open question. Two M2 checks were rephrased so this
  proposal can test them.

## References

- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): a controller controls what it opened
- [ADR-16](../adr/ADR-16-a-program-can-name-what-it-made.md) (proposed): a program can name what it made
- UTERM-004: "How uniterm knows which pane a program runs in"
- UTERM-015: "Where a routed pane goes"
- UTERM-064: "The own-tab alias for a caller with no source tab"
