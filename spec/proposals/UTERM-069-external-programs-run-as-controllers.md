# UTERM-069: External Programs Run as Controllers with an External Source

**Status:** accepted
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- UTERM-004: process-ancestry binding, the session root, and Pending Requests, which this proposal keeps. Give Group is
  never offered to an external program, per "How the user hands an external program a pane"
- UTERM-021: declared permissions, which an external program must carry
- UTERM-015: routed placement for an open with no origin pane, which an external program's first pane follows
- UTERM-067: every remembered approval lives in one store, `policy.json`, read entry by entry under ADR-18, which the
  external coverage on an approval relies on
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
- ADR-14 — P2 ties a run's windows to its source window. An external program has none. See "What an external
  program's window is".
- ADR-16 P3 and UTERM-064 — "uniterm never fills in a program's target from the user's focus or selection", and
  UTERM-064 removes nearest targets, including on calls that make a new place. The first pane's placement anchors to
  the focused pane of the most recently key window. This proposal reads that anchor as placement, not a target: the
  program gains no reach on the focused pane, as a routed open's pane gains none.

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
  read from the process's arguments and marked as claimed. Since no direct client is verifiable (see "What counts as
  code uniterm can verify"), the sheet shows every direct client's arguments as claimed, with no attempt to detect an
  interpreter.

Rationale: everything trust needs already exists for controllers: a declaration, an identity check, the sheet, and
remembered trust per version. An external program differs only in where it starts. Requiring a declaration keeps
strict mode meaningful. uniterm reads every caller's audit token and the executable's code identity
(`ControllerIdentity.swift:253`), but that names only the executable. It cannot verify which script an interpreter
runs: the arguments are only a claim, the file can change, and the script can load other code. See "What counts as
code uniterm can verify". ADR-14 P9 says "the identity
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
"Not traced to a uniterm tab" or "Started in tab 'build', no longer attached". The line never claims where an untraced
program started, since a program in tmux, or one in a tab while terminal identity is broken, is untraced too. A tab title in the origin line is text a
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

### What an external program's window is

Original question: ADR-14 P2 says "Its windows are the source window, which holds that source pane, plus the windows the run itself
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

Decision: D, added by the review: the window is only where its panes sit, and it ends with the window. The program
reaches only the panes it opened, and it gains nothing in its window by position. Its later opens land in that window.
Its source ends on disconnect, process exit, revoke, or when its window closes. A closed window is never replaced by a
new one for the same run. (autonomous)

Rationale: reach stays what ADR-14 P2 allows, so no amendment is needed. Ending with the window honors P5, which makes
the user's close of a run's window final. Option A would open a new window after the user closed one, against P5.
Option B amends P2 to grant scope by position and gains nothing, since window scope adds no pane reach to a program
with no source pane. Option C reverses the settled placement. Converged in 1 pass.

### What counts as code uniterm can verify

Original question: A direct client run as `node client.js` reads to uniterm as `node`, a signed compiled executable. Its code hash says
nothing about the script. If the sheet offered it Trust This Version, any node script sending the same declaration
would get standing powers with no prompt. ADR-14 P9 forbids that. The same holds for bun, deno, a custom interpreter, and
any program that loads plugins. No code today recognizes an interpreter.

- A. Only runs through uniterm's command, including a native controller package's entry, are verifiable. A direct
  client never gets Trust This Version.
- B. A direct client gets Trust This Version only when its executable is signed by a team the user names on the sheet.
- C. A list of known interpreters is excluded, and every other compiled direct client may be trusted. A missing
  interpreter fails open.

Decision: A. Only runs through uniterm's command are verifiable, including a native controller package's entry. A
direct client is never offered Trust This Version. (autonomous)

Rationale: uniterm's own snapshot and the bundled command's signature prove what code runs, as ADR-14 P9 and C2 ask.
A signed executable's code hash proves nothing about the bytes it reads: `nc` or `socat` relays whatever is piped in,
and `node` runs any script. Trusting a developer team would trust every tool that team signs, and uniterm's own builds
carry no team. A list of interpreters fails open for any it misses.

Leaves undone: a compiled direct client is approved once or for a run. To be trusted per version, it ships as a native
controller package and runs through `uniterm controller run`. Converged in 1 pass.

### Whether remembered trust covers a run started outside a tab

Original question: `proceed` admits a run that a remembered policy covers, wherever the run started (`ScriptControllers.swift:262-272`).
Today Grant Access still gates a trusted controller started outside a tab. Without it, any process of the same user,
from cron, ssh, or launchd, can run a trusted controller and get its standing powers with no prompt.

- A. Remembered trust covers tab-source runs only. An external run of a trusted version still asks once per run.
- B. Remembered trust covers external runs too, and the risk is accepted.
- C. A trusted version records whether it may run as external, and the sheet asks that once.

Decision: D, added by the review. A remembered policy records which source kinds it covers. Every policy that exists
before this change, and every Trust This Version chosen on a tab run, covers tab runs only. The first external run of a
trusted version shows the sheet, and choosing Trust This Version there adds external coverage. The coverage is part of
the approval's own entry in `policy.json`, so revoking the approval removes it, and it applies to whatever the entry's
selector matches, a version or an identity. (autonomous, addition) Amended 2026-11-26; see Decision Log.

Rationale: today Grant Access gates a trusted controller started outside a tab, since every call it makes is refused
until the user grants a pane (`ScriptHost.swift:666-682`). Widening existing policies to external runs would increase
an approval without the user's consent, which ADR-14 P10 forbids. Asking on every external run would make remembered
trust useless for unattended programs. Asking only on the first external run of a version puts the question where it
matters. Keeping coverage in the approval's own entry follows UTERM-067, which keeps every approval in one store
because separate stores make a revoke miss part of an approval. Under ADR-18, an older build keeps an entry it cannot
read instead of acting on it. ADR-14 P13 does not decide this: a run through the bundled command is identified. An
earlier version of this decision kept coverage in a store of its own, on the reason that an unknown field makes an
older build refuse the whole policy file. That reason does not hold once UTERM-067 lands.

### Whether a direct client in a tab declares

Original question: Today a program that talks to the socket directly and starts in a tab sends a plain begin and is admitted without
being asked (`ScriptUndeclared.swift:145-160`). Strict mode covers only runs through uniterm's command. Under this
proposal the same program started outside uniterm must declare, so the one in a tab gets more power with less review.

- A. Every direct client declares, wherever it starts. Strict mode refuses one that declares nothing.
- B. Only an external direct client declares. A direct client in a tab keeps today's admission.

Decision: B. Only an external direct client must declare. A direct client in a tab keeps today's admission, and may
still declare to get standing powers through the sheet. (autonomous)

- A plain client in a tab reaches its own pane and the groups it owns, behind the remote-control switch, and each
  sensitive call asks (`ScriptConsent.swift:552-561`). It holds no standing powers.
- A plain client in a tab that loses its link becomes an external program that declared nothing, so strict mode
  refuses it.

Rationale: the question's claim that a client in a tab gets more power with less review holds only for reach. Ancestry
gives it its source pane, and every sensitive call still asks. Requiring a declaration of every client in a tab would
break every existing one under the default strict mode. Since a direct client is never trusted per version, each run
would then show the sheet, the habitual approval ADR-14 warns against. Converged in 1 pass.

### How an external program opens its first pane

Original question: `openPane` requires a `beside` target (`ScriptProtocol.swift:308-310`), and an external program has no pane to name. A
first open needs a form with no anchor, which lands by the settled placement. This is a change to the script wire.

- A. `open-pane` takes no anchor for a caller with no source, and lands by the settled placement.
- B. A separate call opens a program's first pane.

Decision: C, added by the review. The `beside` target gains a third form that names the caller's own window. It
means "in my window", and before the program has a window, the pane lands by the settled no-origin placement. It is a
new target tag, refused by name for a caller with a source pane and on every call other than opening a pane. Later
opens name the same form and land in that window. (autonomous)

Rationale: an omitted target cannot carry the meaning. UTERM-063 says a changed omission takes a new name, and UTERM-064
refuses a command that names no target. A separate call would duplicate `open-pane`'s checks: the applet kind, the
control combination, the directory check, and the order of the authority recheck (`WindowScripting.swift:173-226`).
The new form fits UTERM-064's aliases: it is fixed for the caller's lifetime, since closing the window ends the source.
An old app refuses the unknown target form by name. Converged in 1 pass.

### What a program that loses its link keeps

Original question: A program started in a tab was approved as a tab-source run. When it loses its link, it becomes external. A program
can also choose to lose its link, by double-forking.

- A. Its approval ends with the link, and it asks again as an external program. Its groups are released.
- B. Its run approval carries over, and its source becomes external with the reach of an external program. Which
  window becomes its window, and whether it keeps groups in other windows, follows from "What an external program's
  window is".

Decision: A. Its approval ends with the link. It asks again as an external program, and the groups it owned are
released, as when a run ends. (autonomous)

Rationale: this is today's behavior. A link break ends the connection's authority, which releases every group it owned
in every window (`ScriptHost.swift:693-700`, `authorityEnded` at `797-804`). Carrying the approval over would let a
version trusted on a tab run act as external with no sheet, against "Whether remembered trust covers a run started
outside a tab". It would also keep a `nohup` job acting after the user closed its tab. Converged in 1 pass.

### Whether opening a new window is its own permission

Original question: ADR-14 P8 keeps powers separate. Under the settled placement, an external program's first open can make a new window
when no window exists or there is no room.

- A. Opening a pane covers the window it lands in, wherever it lands.
- B. An external program declares a separate window power to be allowed a new window.

Decision: C, added by the review. Pane control covers the window an external program's first pane may open. The
approval sheet says so in one line, and the one approval covers it, as UTERM-015 settled for an approved outside open:
"The question says that a new window may open." (autonomous)

Rationale: ADR-14 P4 makes opening a window a power of its own, and P8 says no granted power silently grants another.
Saying it on the sheet makes the grant explicit, so nothing is silent. A separate window permission would refuse a
program in a small window, or while any sheet is up, on state the program cannot see. Converged in 1 pass.

### Whether an external program's opens take focus

Original question: The question assumed that UTERM-036's activation covers a program's `open-pane`. A background external program could
then move the user's typing into a pane it controls.

- A. An external program's opens take focus as the user's do, per UTERM-036.
- B. An external program's opens never activate uniterm or take focus.

Decision: C, added by the review: no change. An external program's open behaves as every program's `open-pane` does
today. The new pane takes focus within its window, and uniterm is not activated (`MainWindowController.swift:787`). A
first open that makes a new window shows it, but does not make it key while uniterm is inactive. (autonomous)

Rationale: UTERM-036's activation covers routed opens, `uniterm open` and Launch Services, each approved per open. It
never covered `open-pane`. One behavior for every source kind keeps ADR-15's rule that an action means one thing,
whoever starts it, and never activating uniterm keeps a background program from taking the user's typing in another
app. Converged in 1 pass.

### Whether a broken terminal identity is accepted

Original question: UTERM-004 names a broken terminal identity patch as a risk, and says unavailable identity "offers the explicit-grant
path". That path never covered this failure: Grant Access lists only panes with a recorded session root
(`PendingRequestsWindowController.swift:549`), and a broken identity records none. With identity unavailable, no program
traces to a tab, so every program becomes external, and scripts that act on their own pane are refused.

- A. Accepted, as for tmux: programs still run as external and open their own panes.
- B. A mitigation: the app refuses to start programs from tabs while the identity patch is broken, and says why.

Decision: A, with the risk stated truthfully. Accepted: programs still run as external and open their own panes. A
broken patch cannot ship, since the patch apply and the Swift compile fail, and the process-start integration tests
catch a silent regression in CI. The uncovered case is a macOS update that stops uniterm reading a setuid-root login's
process info on a shipped build. The sheet never claims where an untraced program started. (autonomous)

Leaves undone: until a fixed build ships, no script can act on its own pane, and every plain direct client in a tab is
refused under strict mode. A REPL helper waits for its pane's identity and is refused.

Rationale: this is strictly better than today, where the same failure leaves the program with no pane to be granted.
Refusing programs started from tabs needs the very fact the broken identity cannot supply, so it would refuse every
untraced program, including cron and tmux runs. Converged in 1 pass.

### What an external program may do before its first pane

Original question, added by the review: an external program's calls need a window and a pane today
(`ScriptWindowAPI.swift:47-56`), and it has neither until it opens one. Which calls work before its first pane?

Decision: until its first pane opens, an external program may make only calls that need no window, such as the
clipboard under its declared permissions. Every call that needs a window, such as a form, a status post, a listing, or
a send, is refused with text that says to open a pane first. A form never opens a pane by itself. (autonomous)

Rationale: a form or status post placed by itself would open a window the program never asked for, and would have to
decide whether that window is the program's. Requiring the program to open its pane first keeps one way in, and the
window and lifetime decisions apply unchanged.

### How a direct client is reviewed again

Original question, added by the review: reviews coalesce and Deny is kept by a controller's version, and a direct
client has only a claimed name. A client run by cron every minute after a Deny would make a new review each time.

Decision: a direct client's review and its Deny are keyed on its executable's code identity together with its declared
name. A denied client is refused without a new review until the user chooses Ask Again. Pending reviews keep today's
bound on waiting requests. (autonomous)

Rationale: the executable's code identity is what uniterm can establish, and pairing it with the declared name keeps
two clients of one interpreter apart for the user's Deny. The bound keeps Pending Requests from filling, as ADR-14 P15
asks. A Deny is not a trust, so a claimed name is enough to key it: a program that changes its name only gets asked
again.

## Design Decisions (Open)

None.

## Risks

- **Programs that rely on Grant Access stop working** — likelihood: medium, impact: low.
  A program started outside uniterm that makes calls without declaring permissions is refused under strict mode.
  Accepted: the only such programs are the user's own, and each can declare, through uniterm's command or the
  declaration message.
- **Refusals by name need UTERM-063 M2** — likelihood: medium, impact: low.
  Today an unknown message type or target form closes the connection as a protocol violation, so the client sees the
  socket close, not a named refusal. Mitigation: this proposal lands after UTERM-063 M2, which builds the refusal by
  name, and its queue rows depend on it.
- **A launch from an external program starts a tab-source run** — likelihood: low, impact: medium.
  An external program with host-launch permission could start `uniterm controller run` in a terminal pane it opened. If
  that run binds to the new tab, it gets tab-only trust without the external sheet. Not traced: whether a host launch
  records a tab session root. M1 checks it.
- **Unanswered reviews fill the connection slots** — likelihood: medium, impact: high.
  A review waits until the user answers or the program exits, and each waiting review holds one of the listener's 32
  connection slots (`ScriptListener.swift:13`). A cron job that runs every minute, unanswered, fills them, and every
  later script is refused, including the user's own in tabs. This happens today for untrusted runs and for clients
  waiting on Grant Access, and external direct clients reach it too. Mitigation: a Deny refuses later runs of that
  client without a review. The underlying bound is filed as a bug.
- **Direct clients built before the declaration message** — likelihood: high, impact: low.
  An existing direct client sends a plain begin and no declaration. Under the new app it is refused at its first call.
  Mitigation: the refusal names the declaration message, under UTERM-063's rule that a stale program is refused by
  name, never reinterpreted. A new client against an older app is refused at the unknown message, the same way.
- **Remembered trust admits a run started from anywhere** — likelihood: medium, impact: high.
  Today a trusted controller started outside a tab still needs Grant Access before it acts. Without it, any process of
  the same user, from cron, ssh, or launchd, can run a trusted controller and get its standing powers with no prompt
  (`ScriptControllers.swift:262-272`). Mitigation: a policy covers tab runs only until the user trusts the version
  on an external run. See "Whether remembered trust covers a run started outside a tab".
- **Programs in tmux or screen are always external** — likelihood: high, impact: medium.
  Their server detaches, so a program inside never traces to a tab, and each run goes through the sheet. Accepted: the
  sheet's origin line says so, and the program opens its own panes. It cannot act on the tab it visibly runs in.
- **A terminal identity failure makes every program external** — likelihood: low, impact: high.
  Every program in every tab becomes external, and scripts that act on their own pane are refused. Accepted: a broken
  patch cannot ship, CI tests catch a silent regression, and programs still run as external. Grant Access never
  covered this failure. See "Whether a broken terminal identity is accepted".
- **The design rests on in-flight proposals** — likelihood: medium, impact: medium.
  UTERM-064 is in review, UTERM-054 supplies the tab scope a tab source implies, and UTERM-066 changes exec driver
  identity, which a pane source relies on. Mitigation: each is a dependency or an impact here, and a change to them
  reopens the matching decision.
- **An external program's first pane lands in the user's working window** — likelihood: high, impact: low.
  Mitigation: it lands where any outside open lands, it reaches only that pane, and the pane's badge names it as
  external.
- **The external source becomes a cross-cutting authority kind** — likelihood: high, impact: medium.
  Every check that asks for a program's source answers by kind, and a missed case could treat an external program as a
  tab source. Mitigation: the script host's source is one type with tab and external kinds, so each of its checks must
  handle both to compile. Exec drivers keep their own checks outside the script host, so the pane kind is checked
  there.

## Milestones

### M1: Source kinds and the external source

**Status:** NOT STARTED

- A program's source is a tab, a pane, or external. A REPL helper is a tab source for its REPL pane's one tab. One whose
  pane's identity never arrives is refused with text that names the missing identity
- A program that uniterm cannot trace to a tab, and one whose ancestry breaks mid-run, is external
- An external program makes no effect before the user approves it
- An external program whose origin is tab X is refused on tab X, and pane, tab, and capture calls are each tested for
  every kind
- An external program reaches only the panes it opened, each behind its remote-control switch, and none of the tabs it
  did not open. Give Group is never offered to it
- An external program's first pane opens where an open with no origin pane lands, and that window becomes its window
- Its later opens land in that window, and one that finds no room there is refused with a named reason
- Closing its window ends its source, and it never opens a replacement window for that run
- A pane of its that the user moves to another window leaves its reach
- The window and authority checks that anchor on a caller's pane take the program's window as the anchor for an
  external caller, and refuse a call that needs a pane before the first one opens
- The new target form for the caller's own window is refused by name for a caller with a source pane, and on every call
  other than opening a pane
- An open into its own window lands beside the program's most recently opened pane that is still open there, or else
  splits the window's largest pane. A first pane joins the program's own group, unlike a routed open's pane
- Before its first pane, an external program's calls that need a window are refused with text that says to open a pane
  first
- An external native controller built before this change, whose open names its own pane, is refused with text that
  names the own-window form
- A run started by an external program's host launch is checked for whether it binds to a tab, and does not gain
  tab-only trust through it
- A program that wants a layout first opens one pane, then lays out from it
- An external program's open never activates uniterm, and a new window it makes is not made key while uniterm is
  inactive
- A run whose link breaks, by re-parenting or a closed session, shows the sheet again, and its earlier run approval and
  its per-connection pending requests admit nothing
- An open right after the program's own approval sheet closes lands beside the focused pane, not in a new window
- An external program's panes and badge read "External" with its name, never as the user's shell
- Each program's origin is recorded and shown, and no authority check reads it
- `uniterm open`, `uniterm ask`, and Launch Services opens from outside uniterm behave as before

### M2: Approval on the controller sheet, and Grant Access removed

**Status:** NOT STARTED

- An external program that declares nothing is refused under strict mode, with text that says to declare its
  permissions
- An external program is approved on the controller sheet with its name, path, process ID, signature or version, and
  origin line, and no place picker. The sheet says its first open may make a new window
- A direct client declares with the declaration message, and one that sends a plain begin is refused by name in strict
  mode
- The declaration message uses a new message tag, never a reused one, and a decoder built without that tag refuses it
  by name with text that says to update uniterm
- The sheet quotes and bounds a direct client's claimed arguments, as it does a tab title
- A `uniterm controller run` of an untrusted version started with no tab session, such as from cron, reaches the sheet
  as external. A trusted version follows the answer to "Whether remembered trust covers a run started outside a tab"
- An undeclared run through uniterm's command from outside uniterm in unsafe mode gets the undeclared review, as in a tab
- A policy made before this change covers tab runs only. The first external run of a trusted version shows the sheet,
  and its Trust This Version adds external coverage to the approval's entry in `policy.json`. That sheet says the
  trust also covers runs started outside a tab
- A denied direct client is refused without a new review until Ask Again, and waiting reviews keep today's bound
- In unsafe mode, an external program that declares nothing gets the undeclared review before it is admitted, as an
  undeclared run does, and makes no effect before the user answers. Its calls are held, not refused, until then: Allow
  runs them, and Deny refuses them
- An external run never gains a standing scope that no sheet said covers runs started outside a tab. A Trust that
  merges scopes into an entry with external coverage says on its sheet that the merged scopes cover runs started
  outside a tab
- Trusting on a tab run's sheet keeps an entry's existing external coverage
- The external sheet offers Trust This Identity for a signed package, and choosing it adds external coverage to the
  identity's entry
- A build with UTERM-067's reader and without this proposal keeps an entry's external coverage across a save. An entry
  with no external coverage is written without the new field, so an older build still honors its tab trust
- A coalesced direct-client row shows the oldest connection's process ID and claimed arguments, and Allow admits that
  connection only
- A per-call denial for an external direct client is keyed as its startup Deny is, never by the connection alone
- Revoking an approval removes its external coverage, and the Controllers window shows which approvals cover external
  runs
- A trusted identity's external coverage covers its new versions on external runs, as its tab coverage does
- A direct client in a tab is admitted as today, and the strict-mode text describes only external programs and runs
  through uniterm's command
- A native controller entry's own connections are adopted as today, with no declaration of their own
- A direct client is never offered Trust This Version, and the sheet marks its arguments as claimed
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
  declaration message on the script wire, and reading process arguments) Reach is now only what the program opens, and handing it a pane is an open question. Added open questions on the first pane's
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
- 2026-11-26: Review start: 2 milestones, 7 settled decisions, 9 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the draft, as committed in "Draft UTERM-069:
  external programs run as controllers".
- 2026-11-26: What an external program's window is: only where its panes sit, and its source ends when the window
  closes, with no replacement window. (autonomous)
- 2026-11-26: What counts as code uniterm can verify: only runs through uniterm's command. A direct client is never
  trusted per version, which withdraws the code-identity trust path logged earlier. (autonomous)
- 2026-11-26: Whether remembered trust covers a run started outside a tab: a policy records the source kinds it covers,
  existing ones cover tab runs only, and the first external run asks. Kept in a store of its own. (autonomous, addition)
- 2026-11-26: Whether a direct client in a tab declares: no. Only an external direct client must declare. (autonomous)
- 2026-11-26: How an external program opens its first pane: a new target form names the caller's own window, refused
  for a caller with a source pane. (autonomous)
- 2026-11-26: What a program that loses its link keeps: nothing; it asks again as external and its groups are released,
  as today. Corrected the question's premise, which said its groups remained. (autonomous)
- 2026-11-26: Whether opening a new window is its own permission: no; the sheet says a first open may make a new window,
  and the one approval covers it, as UTERM-015 does. (autonomous)
- 2026-11-26: Whether an external program's opens take focus: as every program's `open-pane` does today, focus within
  its window, never activating uniterm. Corrected the question's premise about UTERM-036. (autonomous)
- 2026-11-26: Added ADR-16 P3 and UTERM-064 to Impacts, and read the first pane's anchor as placement, not a target.
  (autonomous)
- 2026-11-26: Whether a broken terminal identity is accepted: accepted, with the risk restated. UTERM-004's claim that
  the explicit grant covers it is false, since Grant Access lists only panes with a recorded session root. The origin
  line now says "Not traced to a uniterm tab" rather than claiming the program started outside uniterm. (autonomous)
- 2026-11-26: Coherence pass. External coverage now lives in the approval's own entry in `policy.json`, under UTERM-067,
  not in a store of its own: the earlier reason was false once UTERM-067 lands, and a separate store made a revoke miss
  the coverage. (autonomous)
- 2026-11-26: What an external program may do before its first pane: only calls that need no window; the rest are
  refused until it opens a pane. (autonomous)
- 2026-11-26: How a direct client is reviewed again: its review and Deny are keyed on its executable's code identity
  and declared name, with today's bound on waiting reviews. (autonomous)
- 2026-11-26: Coherence fixes: removed the UTERM-036 dependency, which never covered `open-pane`; restated the focus
  risk for the case where uniterm is active; added risks on refusals before UTERM-063 M2 and on host launches; stated
  the rule for later opens; routed checks on unsafe mode, Deny, revoke, and identity coverage. (autonomous)
- 2026-11-26: Re-check fixes. Dropped a check on a review wait bound that does not exist: a review waits until the user
  answers or the program exits, as today. An external program that declares nothing gets the undeclared review in unsafe
  mode, as the setting promises. M2 now puts external coverage in the approval's `policy.json` entry, and gained checks
  on merging coverage, identity trust, older readers, coalesced rows, and per-call denials. Added the risk that
  unanswered reviews fill the connection slots. (autonomous)
- 2026-11-26: Closing re-check converged. Routed checks: an undeclared external client's calls are held until the user
  answers; a merge into an entry with external coverage says so on its sheet; an entry with no external coverage is
  written without the new field. (autonomous)
- 2026-11-26: Review gate: kept all. The user confirmed reading the first pane's anchor as placement, not a UTERM-064
  target; accepted the focus risk while uniterm is active; kept asking once and then remembering external coverage; and
  kept direct clients in a tab as they are.
- 2026-11-26: Removed the keyboard-focus risk. It described a user's own trusted program opening a pane while they
  type, which is not a design exposure, and the user said such cases are not the design's to prevent.
- 2026-11-26: Accepted after its review. ADR candidate: every program's source is a tab, a pane, or external, and origin
  never grants anything. Declined: ADR-14 already decides what a controller may reach.

## References

- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): a controller controls what it opened
- [ADR-16](../adr/ADR-16-a-program-can-name-what-it-made.md) (proposed): a program can name what it made
- UTERM-004: "How uniterm knows which pane a program runs in"
- UTERM-015: "Where a routed pane goes"
- UTERM-064: "The own-tab alias for a caller with no source tab"
