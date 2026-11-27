# UTERM-043: Pause Controllers

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Dependencies

- UTERM-004, for pane control, grants, the control badge, exec drivers, and revoke. It is implemented, so M1 can start
- UTERM-019, for M3's controller dialogs and page JavaScript, and M6 "Trusted input", which first lets a controller
  send keystrokes and clicks. M2 checks suspension against each when it lands
- UTERM-024, for M2: a controller's palette commands and keys
- UTERM-028, for M2: a driver's own-pane rows and keys
- UTERM-041, for M2: the markers
- UTERM-042, for M2: the per-controller badge items and the renamed pane-wide revoke, beside which the badge's suspend
  items sit

## Impacts

- UTERM-042 — "Which controllers a tab's menu names" and "Every action is a palette command". The badge's menu gains a
  "Suspend" item for each controller uniterm spawned, beside its revoke item, and each is also a palette command, per
  "Who owns suspend and resume".
- UTERM-024 — "When commands are live". A suspended controller is one more state in which its commands and keys are
  not live, per "A suspended controller's palette commands and keys".
- UTERM-028 — a driver's own pane "still lists the driver's rows and takes its keys". While the driver is suspended it
  does not, per the same decision. This narrows that rule for suspension only.
- UTERM-041 — the markers. They do not change while a controller is suspended, per "How a suspended controller shows".
- UTERM-036 — its accepted risk "Keys in flight reach the new pane" is one of the interruptions suspending a
  controller would stop.

## Summary

The user can suspend a controller and resume it later, as Ctrl-Z and `fg` do for a program in a shell. Suspending
stops the controller's process, so it does nothing until it is resumed. It is not revoking: the controller keeps its
grant, its groups, and its tabs. uniterm suspends the controllers it starts itself, the REPL's helper and exec
drivers. A controller started from a shell keeps that shell's own job control.

## Motivation

The user may need to type something uninterrupted in a tab while a controller runs. A controller can interrupt that
today, though it sends no keystrokes or clicks yet.

- A controller that opens a pane moves keyboard focus to it (`MainWindowController.openPane`, which ends with
  `paneArea.focus(created)`, `MainWindowController.swift`, about line 781).
- A controller that opens a browser tab moves focus into the page it loads. The browser's `open` command
  (`BrowserApplet+Remote.swift`, about lines 92-115) opens and selects the tab, then commits the controller's URL in
  the same turn. The load makes the tab's web view first responder (`beginTypedLoad`, `BrowserApplet.swift`, about
  line 479). Keys the user is typing then reach the page the controller chose, and that page's own scripts can read
  them.
- UTERM-036 accepts this as the risk "Keys in flight reach the new pane". ADR-15's consequences say a program's action
  "can move the keyboard".

UTERM-019 adds more. M3 gives a controller dialogs that take the first responder when their pane held focus, and lets
it inject JavaScript into any page in its tabs. M6 "Trusted input" lets a controller send synthesized mouse, key, and
scroll events to browser tabs it owns.

The only ways to stop a controller today end something. Revoke Controller ends every controller of a pane, and its
groups stay with no owner (`revokeController(_:)`, `MainWindowController+Control.swift`, about line 121). Disconnect
Pane refuses every program's call to one pane, and both it and Enable Remote Control issue a new control generation, so
the browser releases every tab a controller owns (`BrowserApplet+Remote.swift`, about line 219).

Job control does not cover every controller either. Tested on macOS:

- A `uniterm run` started from a shell is that shell's job. Ctrl-Z stops it and `fg` resumes it today.
- The REPL's helper is the session leader of its own pty, and its parent is in another session, so its process group
  is orphaned. The kernel discards a terminal's Ctrl-Z for it, and a `SIGTSTP` from its parent too. Ctrl-Z in the REPL
  does nothing.
- An exec driver is started by uniterm with no shell around it (`ExecTransport.swift`, about line 139), so nothing
  offers it job control.

The user asked for this during UTERM-041's review, as "pause at next action" or "pause all controllers". At this
review the user set what it means: control over the controller itself, as job control gives, not a block on uniterm's
interface.

## Design Decisions (Settled)

### Pause is not revoke

Decision: pausing never ends a grant, never removes a controller's groups or tab ownership, and never kills its
process. Resuming restores exactly what the controller had. Chosen by the user on 2026-11-21.

Rationale: the user wants a short, uninterrupted stretch, not the cost of a new grant or a new run.

### The proposal stays deferred while controllers send no input

Decision: this proposal stays `deferred` for as long as controllers cannot send keystrokes or clicks. Its revisit hook
is UTERM-019 M6. Chosen by the user on 2026-11-21.

- The deferral has ended. The hook, "when UTERM-019 M6 is scheduled or starts", fired on 2026-11-21 when M6 was
  scheduled, before UTERM-019 M3 had started. The user chose to resume the design, so it is settled before M6 starts.
  Amended 2026-11-21; see Decision Log.

Rationale: without synthesized input, no controller can type into the tab the user types in.

### Whether the deferral still holds

Original question: the deferral rests on controllers sending no keystrokes or clicks. They send none today, but they
already move the keyboard by opening panes and browser tabs, per the Motivation. A controller with browser navigation
can load a page it serves, and focus lands in that page, so the page can read what the user types today. UTERM-019 M3
adds dialogs and injected JavaScript before M6. The candidates were keeping the M6 hook, moving the hook to M3, and
ending the deferral now.

Decision: keep the deferral and the M6 hook. Chosen by the user on 2026-11-21, after the critique raised it.

- Leaves undone: until this proposal's M1 ships, a controller's pane and tab opens still take the keyboard, and a page
  it loads can read the user's keys, with no way to pause it. UTERM-036 accepts the focus moves as "Keys in flight
  reach the new pane". Amended 2026-11-21; see Decision Log.

### What suspending a controller means

Decision: suspending a controller stops its process, as Ctrl-Z stops a program in a shell, and resuming continues it.
It is not a block on uniterm's interface. Chosen by the user on 2026-11-21, at the review gate.

- A suspended controller does nothing at all: it sends no calls, and its own timers and work stop with it.
- A call it had already sent still runs, and its reply waits for it.
- A page it loaded, and JavaScript it injected, run in WebKit's processes and keep running.
- A driver freezes whole, the rendering of its own pane included.
- Suspend is an action on the controllers running when the user chooses it, not a lasting state. A controller that
  starts later is not suspended, so no new run is held past its 5-second limit to declare itself.
- The clear meaning of the freeze matters more than a freeze of everything.

Rationale: a pause the controller can work around is not a pause. Job control is a model users already know, and a new
meaning for "pause" where the process keeps working until it next calls uniterm would confuse them. This replaces the
earlier design, which held each call at uniterm's interface; see Decision Log.

### How the REPL suspends a controller

Original question: the REPL's helper is the session leader of its own pty, so the kernel discards a terminal's Ctrl-Z
for it, and the REPL must catch the key itself. The REPL carries context between lines. The candidates were stopping
the whole helper process, suspending only the running form's fiber and keeping the prompt, both by entry point, and no
REPL key.

Decision: Ctrl-Z in a REPL pane, caught by the app as Ctrl-C already is, stops the whole helper and everything it
started. The pane says the REPL is suspended. Its context is kept, since the process is frozen whole. No new line runs
until the user resumes. Chosen by the user on 2026-11-21, converged in 1 pass.

- The REPL's hang check stands down while the helper is stopped. Today it ends a helper about 3 seconds after a ping
  goes unanswered (`ScriptReplLimits.swift`, about line 51; `ScriptRepl.swift`, about line 208).
- Ctrl-Z in the pane and uniterm's own suspend set one state. Either way of resuming undoes either way of suspending.

Rationale: freezing the whole helper has one meaning, the same as Ctrl-Z on a program in a shell. Suspending only the
running form would leave the REPL working while the controller is meant to be stopped. It would also resume
unreliably: a Janet fiber whose signal mask catches interrupts moves on when interrupted, so its parent continues past
it, and the inner work never resumes (`janet.c`, about lines 16776-16784). A form blocked in a C call, such as a
uniterm call or a sleep, would not suspend until that call returned.

### Who owns suspend and resume

Original question: controllers run as a `uniterm run` or other script started from a shell, in a uniterm pane or
outside uniterm; as the REPL's helper; or as an exec driver uniterm launched. The candidates were uniterm owning only
what it spawned, with or without a control for each controller; uniterm stopping any controller by its process; and
uniterm offering no suspend.

Decision: uniterm suspends and resumes the controllers it spawned: the REPL's helper and exec drivers. Each one has its
own Suspend and Resume, in its badge's menu beside its revoke item, and as palette commands. "Suspend All" and "Resume
All" act on every such controller in every window. A controller started from a shell, in a uniterm pane or outside
uniterm, keeps its shell's Ctrl-Z and `fg`, and uniterm shows when a local one is stopped. Chosen by the user on
2026-11-21, converged in 2 passes. (addition)

- uniterm stops a driver by its process group, which it created, and the REPL's helper by its process group too. The
  helper leads its own session, so that group holds only the helper and what it started, such as a child a REPL with
  the subprocess capability spawned. Amended 2026-11-21; see Decision Log.
- A REPL that controls no pane has no badge. It is suspended by Ctrl-Z in its pane, its palette commands, and Suspend
  All, and resumed by those or the window slot.
- "Resume All" continues every controller uniterm suspended. It never continues a controller uniterm did not suspend.
- The addition is the badge and palette items for each controller, and the stopped display for controllers uniterm
  did not spawn.
- Leaves undone: a controller started with no job-control shell, such as by launchd or by a script without job
  control, can be suspended only with `kill -STOP`. A controller's state is read from its local process, so a script
  reached through a forwarded socket over SSH shows as running.

Rationale: uniterm signals only process groups it created, so it never stops the wrong process. A script's peer can be
a local `ssh` client forwarding the socket, and stopping that would freeze the user's whole session. A foreground job
that uniterm continued would run in the background as far as its shell knows, and stop again when it touched the
terminal. The user's words were that making Ctrl-Z work correctly in a shell is sufficient, and that the REPL needs job
control of its own. A control for each controller gives control over one controller at a time, as revoke already does.

### What uniterm sends a suspended controller

Original question: a stopped peer reads nothing. Script connections queue at most 64 messages or 1 MiB before uniterm
disconnects them, and an exec driver's transport fails at 4 MiB. The candidates were holding events bounded and
reporting drops, today's behavior, dropping events, and lifting the limits.

Decision: no change. Chosen by the user on 2026-11-21, converged in 1 pass.

- uniterm sends a script only replies to its own calls and control messages, never events (`ScriptProtocol.swift`,
  about lines 958-1000). A script has at most 8 calls in flight, so a stopped script cannot reach the 64-message bound.
  The REPL's pings stop with its hang check.
- A driver keeps receiving its own pane's events, in order. Only more than about 15,000 of them during one suspension
  would fill 4 MiB. The risk "A suspended driver's events overflow" records it.

Rationale: current behavior already meets the need. Holding events with a drop count, or dropping them, would add an
exec-wire message today's drivers cannot parse, and a dropped state event would leave a driver's view stale. Lifting
the limits would remove the memory guard.

### The name

Decision: "Suspend" and "Resume", used the same way in the menu, the palette, the badge, and the pane's message.
Chosen by the user on 2026-11-21, converged in 1 pass.

Rationale: it names a frozen process and matches the shell's own word, since zsh prints "suspended". "Pause" reads as
stopping at the next action, which is not what this does. "Stop" already means ending or interrupting in uniterm.

### How a suspended controller shows

Original question: what tells the user a controller is suspended, in its pane, its badge, and the window, and whether
UTERM-041's markers change. The candidates were the badge, the pane, and a window slot together; the badge and the pane
alone; the window slot alone; and a distinct look for the badge's antenna.

Decision: a suspended controller's badge gains a "Suspended" line, and its menu offers Resume. A suspended REPL says
so in its pane, and a suspended driver's pane shows a "Suspended" banner over its content. While uniterm has suspended
any controller, every window shows a status-bar slot naming how many. A click on it opens a menu that lists them, each
with Resume, and Resume All. UTERM-041's markers stay as they are, since the grant stands. Chosen by the user on
2026-11-21, converged in 1 pass. (addition)

- A local controller its shell stopped shows "Stopped by its shell" on its badge, with a line saying to resume it with
  `fg` in its terminal, and no Resume item. The slot counts only what uniterm suspended.
- Wherever a suspension shows, its wording says page code keeps running, and that closing the tab stops it. Leaving
  the page stops only the code of a page the controller loaded. Once UTERM-019 M3 lands, JavaScript the controller
  injected runs again in each new page, until the tab closes or the controller is revoked or ends. A revoke rebuilds
  the tabs whose pages it scripted, except tabs that hold unsent input or a post-result page, which keep a marker
  instead. Amended 2026-11-21; see Decision Log.
- The addition is the window slot.

Rationale: the controller's own pane and badge say what happened where the user looks. Suspend All acts in every
window, so a slot in each window answers the risk of forgetting a suspension made elsewhere. The antenna's look was
chosen by the user, and a pane with one suspended controller and one running one would give it no single meaning.

### How uniterm learns that a controller is stopped

Original question: the REPL's hang check must stand down while the helper is stopped, and uniterm shows a stopped local
controller it did not spawn. Whether uniterm relies on its own record of what it suspended, on the process's observed
state, or both. `proc_pidinfo` reports a stopped process, and a kqueue signal notice fires on every signal without
saying which. The candidates were both, uniterm's record alone, and polling.

Decision: the process's observed state is the truth. uniterm watches each controller's process for signals, and on
each notice it reads the state again after a short delay until the state is readable and settled. The REPL also reads
it in its once-a-second sample. uniterm's own record marks only which suspensions it made, for Resume and Resume All,
and a continue from outside clears it. The badge, the hang check, the slot, and "A suspended controller's palette
commands and keys" all follow the observed state. Chosen by the user on 2026-11-21, converged in 1 pass. (addition)

- The addition is watching processes uniterm did not spawn, which serves the stopped display for shell-started
  controllers.

Rationale: a stop the user made in a shell, or with `kill -STOP`, is still a stop, and the REPL's hang check would
otherwise end a helper stopped that way. A single read right after the notice can find the state unreadable while the
signal is pending, or not yet changed, so a shell's Ctrl-Z would never show. Following uniterm's record after an
outside continue would show a running helper as suspended and keep its hang check down. Polling alone has no record,
so Resume All could not keep to what uniterm suspended. A debugger holding a process at a breakpoint suspends its task
rather than stopping it, so it does not show as stopped, as today.

### What a frozen REPL does with keys

Original question: what Ctrl-Z does at an idle prompt, what Ctrl-C does while the REPL is suspended, and whether keys
typed while it is frozen reach the line editor on resume or are held back by the pane.

Decision: while the REPL is suspended, the pane takes no input. Typed keys, a paste, dragged text, and input-method
composition are not sent to the helper, and the pane says it is suspended. Scrolling and selection still work. Ctrl-Z
resumes, and a held key's repeats are ignored, so it never flips back. Ctrl-C resumes, and when a form is running it
then interrupts it, as Ctrl-C does today. At an idle prompt Ctrl-C only resumes. Ctrl-Z at an idle prompt suspends the
idle REPL too. Chosen by the user on 2026-11-21, converged in 1 pass.

Rationale: each key keeps one meaning. Text typed blind would run on resume, a stray Enter included. Ending the helper
on Ctrl-C would lose the context the suspension kept. Ctrl-Z suspends the REPL whatever it is doing, as the badge's
Suspend does.

### A suspended controller's palette commands and keys

Original question: under UTERM-024 and UTERM-028 a controller declares palette commands and keys, and a key press
reaches it as an event. Whether those stay live while it is suspended, and queue for it, or step aside so the keys
reach the pane.

Decision: they step aside while the controller is suspended, by its observed state. They leave the palette, and its
keys reach the pane as if they did not exist, as UTERM-024 already treats a disconnected member. A driver's own pane
takes no driver keys while the driver is suspended. Revoke and Resume stay reachable there. Chosen by the user on
2026-11-21, converged in 1 pass.

Rationale: this applies UTERM-024's existing rule for a command that is not live. Queued presses would all fire on
resume, so a command pressed three times while suspended would run three stale times, and the pane would lose the keys.
A third, disabled state would swallow keys with no effect and add a state UTERM-024 does not have.

## Design Decisions (Open)

None.

## Risks

- **The user forgets a suspended controller** — likelihood: medium, impact: medium. A controller appears stuck and its
  work silently stops. Mitigation: the badge, the pane, and a slot in every window show it, per "How a suspended
  controller shows".
- **A suspension misread as safety** — likelihood: low, impact: high. A page a controller loaded keeps running while
  the controller is suspended, and so does JavaScript it injected. Either can still read what the user types in that
  tab, and injected JavaScript runs again in each new page the tab loads. A revoke does not stop a page the controller
  only loaded. Mitigation: wherever a suspension shows, its wording says page code keeps running, and that closing the
  tab stops it.
- **A suspended helper outlives uniterm** — likelihood: low, impact: low. If uniterm crashes while it holds a stopped
  REPL helper, the helper's pty master closes. Tested on macOS: a stopped pty session leader whose master closes is
  gone within a second, and so is a stopped child in its process group. A driver's group becomes orphaned when uniterm exits, and the kernel then sends it SIGHUP and
  SIGCONT. Mitigation: an M1 check that no controller uniterm spawned stays stopped after the app is gone.
- **A driver's child escapes the driver's suspension** — likelihood: low, impact: low. A child that calls `setsid`
  leaves the driver's process group, so suspending the driver does not stop it, and if it holds the driver's output
  it can keep sending calls. Accepted: a driver that does this has left its own group on purpose.
- **Suspended REPLs hold the REPL memory budget** — likelihood: low, impact: low. A frozen helper keeps its memory, so
  a new REPL can be refused while suspended ones hold the budget. Accepted: the user can resume or close a suspended
  REPL, and the refusal says why.
- **A suspended driver's events overflow** — likelihood: low, impact: medium. A long, busy stretch on a suspended
  driver's own pane could queue past 4 MiB, and the transport would then fail and end the driver. Accepted: it takes
  more than about 15,000 events, and the failure names the suspension.
- **A shell-less controller cannot be suspended from uniterm** — likelihood: medium, impact: low. A controller started
  by launchd or by a script without job control has no Ctrl-Z, and uniterm does not signal processes it did not spawn.
  Accepted: `kill -STOP` still works, and signalling such a process could stop the wrong one.
- **The revisit hook fires too late** — likelihood: low, impact: medium. Focus moves already interrupt typing, and
  UTERM-019 M3 adds dialogs and page JavaScript before M6. Accepted by the user on 2026-11-21: the deferral keeps the
  M6 hook, per "Whether the deferral still holds". The hook fired on 2026-11-21, when M6 was scheduled and before M3
  started, so the design is settled ahead of both. What stays exposed is order: UTERM-019 M3 may still ship before
  this proposal's M1.
- **Unbuilt proposals shift the surfaces M2 checks** — likelihood: medium, impact: low. UTERM-019 M3 and M6,
  UTERM-024, UTERM-028, UTERM-041, and UTERM-042 are accepted but not started. Mitigation: M1 needs none of them, and
  each M2 check runs when its proposal lands, against that proposal as built.

## Milestones

### M1: Suspend and resume

**Status:** NOT STARTED

Builds only on control code that exists today. It adds each controller's Suspend and Resume to today's badge menu.
M2 places them beside UTERM-042's revoke items once those land.

- Ctrl-Z in a REPL pane suspends the whole helper and the processes it started, by its process group. The pane says
  so, and no new line runs until resume. The REPL's context is the same after resume
- The Ctrl-Z that suspends or resumes the REPL never reaches the pty, so the helper reads no stray byte on resume
- The REPL's hang check never ends a suspended helper. `testAHelperThatStopsAnsweringIsKilledAsHung` is rewritten for
  a helper that is stopped, not hung
- A REPL that controls no pane is suspended from its pane's Ctrl-Z, the palette, and Suspend All, and resumed from
  those or the window slot
- A REPL helper or driver that something outside uniterm stopped shows as suspended, its own Resume continues it, and
  Resume All leaves it alone
- Suspend All during a REPL helper's 5-second declaration does not stop that helper, so the listener never drops it
- A suspended REPL helper at quit is ended at once with its whole process group, by SIGKILL or by SIGCONT and then
  its close, so neither it nor a child it spawned stays frozen
- Revoking a suspended driver leaves it suspended with its own-pane channel. The window slot and its pane's banner
  still offer Resume after its badge items leave the pane it no longer controls
- A script started inside a driver's group stops and resumes with the driver
- Ctrl-Z in the REPL and uniterm's own suspend set one state, and either way of resuming undoes either way of
  suspending
- Each REPL helper and exec driver has Suspend and Resume in its badge's menu and as palette commands. "Suspend All"
  and "Resume All" act on every such controller in every window
- A suspended driver stops whole, the rendering of its own pane included, and resumes with its grant, its groups, and
  its tabs
- "Resume All" continues only controllers uniterm suspended
- Suspend acts on the controllers running when it is chosen. A controller that starts afterwards runs, and declares
  itself within its 5-second limit
- A call a controller sent before it was suspended still runs, and the controller gets its reply on resume
- A stopped driver that is closed, or still stopped at quit, gets `SIGCONT` after `SIGTERM`, so it can shut down
  cleanly
- No controller uniterm spawned, and no member of a REPL helper's process group, stays stopped after the app is gone
- A `uniterm run` that its shell stopped with Ctrl-Z is shown as stopped, and `fg` resumes it as today
- A suspended controller's badge shows "Suspended" with Resume. A suspended REPL says so in its pane, and a suspended
  driver's pane shows a banner. Every window shows the slot while uniterm has suspended any controller, and its menu
  lists each with Resume, and Resume All
- A shell-stopped `uniterm run` shows "Stopped by its shell" and the `fg` line, with no Resume, and the slot does not
  count it
- Every place a suspension shows says page code keeps running, and that closing the tab stops it
- A shell's Ctrl-Z on a `uniterm run`, and a `kill -STOP` on a REPL's helper, both show as stopped, though the first
  read after the signal may be unreadable. A `kill -CONT` from outside clears uniterm's record and the badge
- On resume, the REPL's ping clock restarts, so a ping left unanswered while stopped never ends the helper
- While suspended, the REPL pane sends no typed key, paste, dragged text, or composed text to the helper, and scrolling
  and selection still work
- Ctrl-Z resumes a suspended REPL and ignores repeats. Ctrl-C resumes, then interrupts a running form, and at an idle
  prompt only resumes. Ctrl-Z at an idle prompt suspends the REPL
- A UI test suspends a controller between two of its calls, then types into a pane. The controller opens no pane and
  no tab until it is resumed

### M2: Suspension beside newer control features

**Status:** NOT STARTED

Each check runs when the feature it names has landed, against that feature as built. A check whose feature has not
landed waits for it.

- When UTERM-024 has landed: a suspended controller's palette commands leave the palette, its keys reach the pane as
  if unbound, and its key indicator goes away, all following its observed state
- When UTERM-028 has landed: a suspended driver's own pane takes no driver keys, and Revoke and Resume stay reachable
  there
- When UTERM-041 has landed: a suspended controller's markers do not change
- When UTERM-042 has landed: each controller's Suspend item sits beside its revoke item and "Revoke All Controllers"
- When UTERM-019 M3 has landed: a suspended controller asks for no dialog, and its injected scripts keep running. The
  wording names closing the tab as what stops injected code, since a revoke spares tabs that hold unsent input or a
  post-result page, and code already in their pages keeps running
- When UTERM-019 M6 has landed: the M1 typing test also has the suspended controller's synthesized input arrive only
  after resume

## Decision Log

- 2026-11-21: Drafted at the user's request during UTERM-041's review. The user chose that a pause never revokes or
  kills, and that the proposal stays deferred until controllers can send keystrokes or clicks, with UTERM-019 M6 as
  its revisit hook.
- 2026-11-21: Critique pass. Corrected the Motivation: controllers already move keyboard focus when they open panes
  and browser tabs, per UTERM-036. Disconnect Pane then Enable Remote Control keeps a grant and its groups, but it
  works per pane and a new control generation makes a browser drop every tab a controller owns. Corrected the wire
  notes: ScriptWire is exempt from ADR-13, and the exec wire is bound by it. Added the open question "Whether the
  deferral still holds", since the deferral's premise is narrower than the interruption it guards against. Added
  options and constraints from ADR-11, ADR-15, and the window's one dispatcher queue, and three risks.
- 2026-11-21: Re-check fixes. A controller's browser `open` puts focus in the page it loads, not the address field, so
  that page can read the user's keys today. The deferral question and the safety risk now say so. `busy` is dropped
  as a refusal kind for a pause, since its meaning is a retry. The M1 checks now cover only the controllers a pause
  covers.
- 2026-11-21: Whether the deferral still holds: the user kept the deferral and the UTERM-019 M6 hook, and accepted the
  risk that the hook fires after focus moves and pages already reach the user's typing.
- 2026-11-21: The critique loop converged in three passes. Its last pass routed two checks to M1: the UI test loads a
  page, and its synthesized-input half applies once UTERM-019 M6 has landed.
- 2026-11-21: "What a pause covers" now cites UTERM-042's settled answer on revoking one controller, which it had
  called an open question. UTERM-042 also renames the pane-wide revoke "Revoke All Controllers" and adds one revoke
  item per controller to the badge. This proposal's Motivation still names "Revoke Controller", since it describes
  today's command.
- 2026-11-21: Revisit audit: act. The hook "when UTERM-019 M6 'Trusted input' is scheduled or starts" fired when
  UTERM-019 M4-M6 was scheduled. The user chose to resume the design before M6 starts. The status moved from deferred
  to designing, and the `**Revisit:**` line was removed.
- 2026-11-21: Review start: 1 milestone, 3 settled decisions, 7 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the 7 open questions, at the commit "Resume
  UTERM-043 now that its revisit hook fired".
- 2026-11-21: What a pause covers: every controller in every window, as one app-wide state, including connections that
  start during it. A driver's own-pane commands keep working, and `uniterm open` is not covered. (autonomous)
- 2026-11-21: Filed `bugs/20261121-held-requests-grow-without-bound.md`: calls held while a peer's full check runs
  have no bound. Not confirmed.
- 2026-11-21: What a command does while paused: a covered call waits at admission and at each later authority re-check
  before an effect, and runs on resume. Nothing is refused, so no script ends at a pause. This also settles that work
  already queued at the pause waits for resume. (autonomous, judge)
- 2026-11-21: "Pause at the next action" and work already running: page code and a driver's own-pane commands keep
  running, the wording says so and names Revoke, and a split release waits like any call. (autonomous)
- 2026-11-21: How the user pauses and resumes: a menu-bar command, a palette command, and a badge item, with no
  reserved key and explicit resume. A paused controller's commands and keys are not live. (autonomous, addition)
- 2026-11-21: How a pause shows: a status-bar slot in every window, whose click opens a menu with Resume, and a "Paused"
  line on the badge. Markers and the badge's look stay. (autonomous, addition)
- 2026-11-21: Whether the controller learns of a pause: ScriptWire gains one notice the helper prints to stderr while a
  call waits. The script code and the exec wire see nothing. Amended "What a command does while paused", which said
  "No wire changes". (autonomous, addition)
- 2026-11-21: Whether a pause survives a relaunch: no. It lives in the running app until resume or quit, whatever
  windows open or close. (autonomous)
- 2026-11-21: Corrected the proposal's layout: the review had left a second "Design Decisions (Open)" heading above
  settled decisions.
- 2026-11-21: Coherence review. Amended "The proposal stays deferred while controllers send no input", which read as
  a deferral still in force, to say it ended when UTERM-019 M6 was scheduled. Rewrote the risk "The revisit hook fires
  too late" to say the hook fired before M3 started. Added UTERM-024, UTERM-028, UTERM-041, and UTERM-042 to
  Dependencies, since M1's checks relied on them unbuilt. Split M1: M1 keeps what builds on today's code, and M2 holds
  each check against a newer feature, run when that feature lands. M2 adds the missing check against UTERM-019 M3.
  Narrowed "How a pause shows" so a run that begins during a pause still files its admission review. Tagged the
  ScriptWire notice an addition. Added a leaves-undone line on a driver's own-pane order, a note that a pending reply
  is answered during a pause, the accepted `busy` retry, and the risk "Unbuilt proposals shift the surfaces M2
  checks". Routed checks to M1 for pending replies, a driver's consent calls, the notice mid-run, and Ctrl-C on a
  waiting REPL line. (autonomous)
- 2026-11-21: Re-check fixes. Amended "What a command does while paused": its list of what answers a waiting call
  `refused` named revoke, run end, and pane close. It now also names a stop request on the connection, so Ctrl-C in
  the REPL cancels a waiting line before it runs. A `uniterm run` in a terminal ends on its second Ctrl-C, as today.
  Amended the leaves-undone line of "Whether the deferral still holds", which said "until M6"; it now says until this
  proposal's M1 ships. The pause's wording names the pane-wide revoke by the name it has when M1 ships. Tagged the
  notice's Decision Log entry an addition. Routed the re-check "not now" result and the notice timing to M1.
  (autonomous)
- 2026-11-21: Growth question: the user kept the requirement that Ctrl-C cancels a call waiting on a pause, in the
  REPL and in a terminal running `uniterm run`, over the REPL alone and over Ctrl-C working as today. The terminal case
  adds a ScriptWire cancel message from the helper. (addition)
- 2026-11-21: Final re-check fix, not re-checked: the proposal loop ran its three passes. Amended "What a command does
  while paused": a cancel from the connection now answers a waiting call `refused` in a terminal too, through the new
  helper message, and only while the call still waits. Amended its bound: it said every connection has its own bound
  with `busy` past it. ScriptWire's in-flight limit of 8 unanswered calls already bounds a connection, per the triage
  of `bugs/20261121-held-requests-grow-without-bound.md`, so only an exec driver gets its own bound. (autonomous)
- 2026-11-21: Risk review: every risk carries a likelihood, an impact, and a mitigation or an acceptance. No risk is
  both high likelihood and high impact. No one-way door: the pause is never stored, ScriptWire's two sides match
  versions exactly, and the exec wire does not change. (autonomous)
- 2026-11-21: Review gate, first call: the user kept the entry points in the menu bar, the palette, and the badge
  (addition), the status-bar slot (addition), and the ScriptWire wait notice (addition). The user asked how pause and
  resume work before answering on what a paused call does.
- 2026-11-21: Review gate: the user overturned "What a command does while paused". A pause suspends the controller
  itself, as job control does, rather than holding calls at uniterm's interface. Calls already sent still run, page
  code is not frozen, and a driver freezes whole. This reopens the decisions built on holding calls: what a pause
  covers, what a command does while paused, work already running, the entry points, how a pause shows, the wait
  notice, the Ctrl-C cancel, and the relaunch rule. The user asked that the semantics be clear rather than that the
  freeze be total. The redesign runs in converge mode.
- 2026-11-21: Tested on macOS: a terminal's Ctrl-Z, and a `SIGTSTP` from its parent, are discarded for a pty session
  leader whose parent is in another session, as the REPL helper is. A shell's job in its own foreground group stops on
  Ctrl-Z, and another process can read the stop and continue it. `SIGSTOP` stops any process, `proc_pidinfo` reports
  `SSTOP`, a kqueue signal notice fires on every signal without saying which, and a stopped process ignores `SIGTERM`
  until `SIGCONT`.
- 2026-11-21: How the REPL suspends a controller: Ctrl-Z in the pane stops the whole helper, its hang check stands
  down, and it shares one state with uniterm's suspend. Chosen by the user, converged in 1 pass.
- 2026-11-21: Who owns suspend and resume: uniterm suspends what it spawned, the REPL's helper and exec drivers, each
  from its badge and the palette, with Suspend All and Resume All. Shell-started controllers keep their shell's job
  control, and uniterm shows a stopped local one. Suspend is an action, not a lasting state. Chosen by the user,
  converged in 2 passes. (addition)
- 2026-11-21: What uniterm sends a suspended controller: no change. Chosen by the user, converged in 1 pass.
- 2026-11-21: The name: Suspend and Resume. Chosen by the user, converged in 1 pass.
- 2026-11-21: Rewrote the proposal around suspension. Removed the settled decisions built on holding calls: "What a
  pause covers", "What a command does while paused", "'Pause at the next action' and work already running", "How the
  user pauses and resumes", "How a pause shows", "Whether the controller learns of a pause", and "Whether a pause
  survives a relaunch". The entries above record what each said. Their checks left M1 and M2, and the risks on held
  commands, ADR-15's reading of a hold, and the ScriptWire change left the Risks. Added "What suspending a controller
  means" from the user's gate answer. Rebuilt the Summary, Motivation, Impacts, Risks, and milestones. Opened four
  questions the new design needs.
- 2026-11-21: How a suspended controller shows: the badge, the pane, and a slot in every window, with markers
  unchanged. A shell-stopped controller shows how to resume it with `fg`. Chosen by the user, converged in 1 pass.
  (addition)
- 2026-11-21: How uniterm learns that a controller is stopped: the observed process state, re-read until it settles,
  with uniterm's record only marking what it suspended. Chosen by the user, converged in 1 pass.
- 2026-11-21: What a frozen REPL does with keys: the pane takes no input, Ctrl-Z resumes, Ctrl-C resumes and
  interrupts a running form, and Ctrl-Z at an idle prompt suspends. Chosen by the user, converged in 1 pass.
- 2026-11-21: A suspended controller's palette commands and keys: they step aside, following the observed state, which
  narrows UTERM-028's own-pane rule for suspension. Chosen by the user, converged in 1 pass.
- 2026-11-21: Coherence review of the rewrite. Amended "How a suspended controller shows": its wording said revoking
  the controller stops page code. A revoke keeps the panes and only clears which tabs the controller owns, so a page it
  loaded keeps running. The wording now says closing the tab or leaving the page stops it, and that a revoke rebuilds
  scripted tabs only once UTERM-019 M3 lands. Amended "Who owns suspend and resume": it said the REPL's helper is
  stopped by its own process. It is stopped by its process group, so a child it spawned stops too, and a REPL with no
  badge is suspended from its pane, the palette, Suspend All, and the slot. Tagged the watch on processes uniterm did
  not spawn an addition. Tested on macOS that a stopped pty session leader is gone within a second of its master
  closing, so a crash does not leave a REPL helper frozen; the risk "A suspended helper outlives uniterm" is now rated
  low impact. Added two accepted risks: a driver's child that leaves its group, and suspended REPLs holding the memory
  budget. Routed checks to M1 for the pty never seeing the Ctrl-Z, the hang test, a REPL with no badge, an outside
  stop, Suspend All during a declaration, quit with a suspended REPL, revoke while suspended, a script in a driver's
  group, and a UI test that suspends between calls. M1 adds each controller's items to today's badge menu.
  (autonomous)
- 2026-11-21: Re-check fix. Amended "How a suspended controller shows" again: it said closing the tab or leaving the
  page stops page code. Once UTERM-019 M3 lands, injected JavaScript runs again in each new page, so leaving the page
  does not stop it. The wording now names closing the tab, and a revoke's rebuild now excludes tabs that hold unsent
  input or a post-result page. The window slot only resumes. Routed to M1 that quit and an ended app take a REPL
  helper's whole group, and to M2 that the wording names what stops injected code. (autonomous)
- 2026-11-21: Final re-check fix, not re-checked: the proposal loop ran its three passes. M2's UTERM-019 M3 check said
  the wording names closing the tab or revoking as what stops injected code. A revoke spares tabs holding unsent input
  or a post-result page, and code already in their pages keeps running, so the check now names closing the tab only.
  Tested on macOS that a stopped child in a stopped pty session leader's group is also gone once the master closes.
  (autonomous)
- 2026-11-21: Risk review: every risk carries a likelihood, an impact, and a mitigation or an acceptance. No risk is
  both high likelihood and high impact. No one-way door: nothing is stored, and neither wire changes. (autonomous)
- 2026-11-21: Accepted by the user. No decision earns an ADR.
- 2026-11-21: Scheduled as M1 and M2 in queue.md. M1 is its own row, since it needs no other proposal, and M2 waits on
  UTERM-019 M6, UTERM-024, UTERM-028, UTERM-041, and UTERM-042.

## References

- UTERM-004: pane control, exec drivers, and revoke
- UTERM-019: M3 dialogs and page JavaScript, and M6 "Trusted input"
- UTERM-024: a controller's commands and keys
- UTERM-028: exec driver commands
- UTERM-036: "Keys in flight reach the new pane"
- UTERM-041: the markers
- UTERM-042: tab actions, per-controller badge items, and palette commands
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): key bindings
- [ADR-13](../adr/ADR-13-outside-wires-stay-compatible-across-versions.md): external wires stay compatible
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): grants and revocation
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): a program's operation is the user's
