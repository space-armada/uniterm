# UTERM-047: Rate-Limit Status Posts per Source

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-27

## Dependencies

- UTERM-001, for the status bar and its message model
- UTERM-003, for `post-status` and the script-named status producer
- UTERM-004, for the transport-established caller and its binding
- UTERM-017, for the shared status queue, producer identities, retention, and repeat coalescing
- UTERM-022, for the requester and the terminal-session key

## Impacts

- UTERM-017 — supersedes in part. Decision Log, 2026-11-06: each script producer is its own source and reads as
  "name (script N)". This proposal keys a script's posts by its terminal session or run, takes the label from the
  transport, and makes the waiting backlog fair across sources.
- UTERM-003 — supersedes in part. The `post-status` call: a script's label no longer comes from its own begin name,
  and a post over the budget behaves per "Hold a source's newest over-budget post". A script's posts go to its pane's
  window, where UTERM-003 sent them to the active window.
- UTERM-001 — supersedes in part. "libghostty allows one notification per second" no longer holds once the patch in
  "Replace libghostty's notification limit with uniterm's budget" lands.
- UTERM-022 — "What a requester is": status reuses its terminal-session key, but keys a bound run by its session where
  the Questions pane keys each run apart. The Questions pane is unchanged.

## Summary

The status bar learns who posted each message from the transport, and shares its turns fairly between sources. A
script's posts are keyed by the terminal session it runs in, so a loop of runs in one tab is one source. Each source
has a budget of bar turns, and uniterm posts its own line when it limits one. A terminal's notifications reach uniterm
without libghostty's app-wide limit, so one terminal never drops another's.

## Motivation

`post-status` needs no power, since a status line is informational. Its space is already bounded. The wire caps a
message at 2048 bytes. Repeats coalesce on the bar. The waiting backlog and the history both have count and byte caps,
and a chatty source gives up its own history rows first.

Nothing bounds it in time or attention, and nothing shares the bar between sources. Once more than three messages
wait, the backlog keeps only errors and the newest message, whatever its source. A script that posts distinct text in
a loop therefore pushes other sources' waiting messages off the bar. Errors from every source fold under the newest
error, which the bar shows with that error's source. The only stop is ending the script.

A per-source limit cannot work on today's key. Each connection gets its own producer. Each `uniterm run` from bash is
its own connection, and the Questions pane's requester keys each run apart too. A loop of runs in one shell looks like
many sources, so a limit keyed by producer or by run would never fire.

The label leaves provenance out. The bar already marks every script as "name (script N)", so a script cannot pass for
uniterm, and two scripts with one name stay apart. But the name is the script's own claim, and nothing says which
terminal or which file it came from. The Questions pane's header shows what the transport established instead.

## Design Decisions (Settled)

### Key a script's posts by its terminal session

Decision: a connection bound through its process ancestry to a terminal session posts as that session, its root and
generation. A bound run, a `uniterm open`, and a generic peer in one terminal tab are one source. A connection the
user granted a pane, and a REPL, are bound too, but keep keys of their own, per the bullets below.

- A connection the user granted a pane, and a REPL, keep a key of their own and their own labels, "<program>, granted
  Pane N" and "REPL in Pane N". A granted program never posts as the pane's shell.
- A connection with no binding cannot post at all today, since every call needs one. A run the user grants a pane
  posts as that grant.
- Two terminal tabs in one pane are two sources.
- A source and its budget outlive the connections that post as it. Their state is bounded in memory.
- Panes, applets, and uniterm keep the keys they have today.
- The Questions pane keeps its own requester, which keys each run apart. A source on the bar and a tab in the Questions
  pane can differ for a run.

Rationale: a limit keyed by connection or by run never fires against the main case, a bash loop of runs. The terminal
session is the unit the user sees: one shell in one tab. Amended 2026-11-27; see Decision
Log.

**Decided by:** user, 2026-11-27

### Take a script's label from the transport

Decision: the bar and the history label a script's posts with what the transport established. A self-reported name
appears only when it is marked as unverified.

- A package run shows the controller ID the user reviewed it under. A declared file shows its ID and "(declared file)".
- A run with no declaration shows its own name with "(unverified script)", as the Questions header does.
- A terminal session shows "Terminal session in Pane N".
- A source with no pane says so.
- The bar may shorten the label. The history row carries the full one, with the terminal session and pane.
- Two sources never share a full label in the history.

Rationale: ADR-14 says the claimed requester scope cannot be narrower than the transport can establish, and that a
self-description is not authentication. Marking the script's own name keeps it useful without letting it pose as
proven.

**Decided by:** user, 2026-11-21

### Share the bar fairly between sources

Decision: the waiting backlog is fair across sources. For each source it keeps the newest waiting error, with later
errors folded into it, and the newest waiting non-error of the highest level waiting. Turns on the bar rotate between
sources. No waiting message is replaced by its source's later message of a lower level. Errors fold only into an error
from the same source.

- The waiting area keeps its existing count and byte bounds. Past a bound, the oldest waiting source's non-error message
  leaves the bar's queue and stays in the history. The `uniterm` source's own lines leave last, so the user's own
  feedback survives a flood. Errors past the bound are not dropped. They are counted in one
  tally across sources, which uniterm shows as a single line from its own source.
- The `uniterm` source keeps each of its waiting lines, within the waiting area's bounds, not only its newest. A limit
  notice then never replaces uniterm's reply to the user's own action, such as "The driver did not start". Every
  program-driven `uniterm` line is bounded where it is made, so uniterm's waiting lines stay few.
- A lone source that posts several lines within one dwell now shows only its newest of the highest level, with an
  error kept apart. Today up to three waiting messages all get turns.

Rationale: the bar is shared attention. A source-blind backlog lets one chatty source push every other source's message
off the bar, even within any time budget. Amended 2026-11-27; see Decision
Log.

**Decided by:** user, 2026-11-27

### Give each source a budget of bar turns

Decision: each source has a budget of turns on the bar, refilled as a token bucket. A post within the budget takes its
turn as today, subject to the fair backlog. A post over the budget waits: it is held as its source's waiting entry for
its kind, and takes the source's next turn once the budget allows. A source holds at most one waiting error and one
waiting non-error. Every post, within or over the budget, keeps its history
record, subject to the existing retention caps.

- The budget runs on the main-actor status center and never waits, per ADR-08.

Rationale: fairness alone leaves a lone chatty source holding an otherwise idle bar for as long as it runs. A budget
bounds that in time. A prompt is the wrong tool: a status line is informational, and asking before each one would defeat
it. A bucket gives a short script its burst and still bounds a long run. Holding the newest post means a burst's last
word, such as "Done" or "Failed", reaches the bar unless the source holds a post of a higher level, and the budget still
meters turns, so a loop gets no more of them. Amended 2026-11-27; see Decision Log.

**Decided by:** user, 2026-11-27

### Report a limited source

Decision: when uniterm starts limiting a source, it posts its own line from the `uniterm` source. The line names the
source by its full transport label. When the source's limited stretch ends, or the source ends while limited, the
history records how many posts were held back: those that never got a turn.

- The notice is bounded. A limited source produces at most one notice per limited stretch. A stretch starts at the
  source's first post that has to wait for the budget, and ends when its budget is whole again.
- The notice posts at info.
- uniterm's own notices are never limited by the budget. That rule keeps a notice from limiting itself in a loop.

Rationale: the user should know why a source went quiet. The line comes from uniterm's own source, so a script cannot
fake it, once no pane line reads as plain `uniterm`. A bucket has no window that lapses, so the stretch marks when the
source is no longer limited. Amended 2026-11-27; see Decision
Log.

**Decided by:** user, 2026-11-27

### Rest the budget on ADR-14 P15 and C1

Decision: the budget is this proposal's bound under ADR-14 P15, that a program's reach is always bounded. A status line
needs no grant under ADR-14 C1, since it only shows the user something.

Rationale: the user amended ADR-14 to state the principle, so this proposal cites it rather than standing alone.

**Decided by:** user, 2026-11-21

### Defer a "mute this source" control

Decision: no control to mute a source. Muting needs a way to list and remove mutes later, and the fair backlog and the
per-source budget bound the problem for now.

**Revisit:** when the user reports a source the budget leaves too loud, or asks to silence one source entirely; file a
follow-up proposal for muting and unmuting.

**Decided by:** user, 2026-11-21

### Budget every source but uniterm's own, and bound the lines a program makes uniterm post

Original question: does the budget cover every source, or scripts only? The fair backlog covers every source either
way.

Decision: the budget covers every source a program or the user's panes can drive. That is panes, applet producers, and
scripts. The `uniterm` source is not budgeted. The lines uniterm posts because a program connected or asked for
something are bounded where they are made, as open refusals already are.

- A pane source is what an applet in a pane posts. That covers a terminal's OSC 9 and OSC 777 notifications, which any
  program in the shell can send (TerminalApplet/TerminalApplet.swift:900-905).
- Each new request from a connection with no binding posts a "Pending request:" line from the `uniterm` source
  (WindowKit/PendingRequestsIndicator.swift:39-44). Each refused connection posts its refusal as a `uniterm` warning
  (`App/AppDelegate.swift:258-261` at the repo root), whether it failed the version check, broke the protocol, or found
  too many connections. A program that connects and disconnects in a loop posts one of these each time.
- Each kind posts at most one line per 30 seconds, and that line counts the ones it folded, the way open refusals
  already do (FileRouting/OpenAuthority.swift:68-100). The Pending Requests window and the bar's request count still
  show every request, and the log keeps every refusal. The lines keep the `uniterm` key.
- uniterm's own lines, the limit notices, and the cross-source error tally are never budgeted. A notice never limits
  itself, and a program's flood never spends a budget that uniterm's own replies to the user's actions need, such as
  "The driver did not start". The `uniterm` source keeps each waiting line, per "Share the bar fairly between
  sources", so a later `uniterm` line never replaces such a reply. A pane's own warnings, such as "The program could
  not start", share the pane's budget with the pane's notifications.

Rationale: one rule for every source fits ADR-15, and it bounds the pane path, which ADR-14 P15 requires. Once
libghostty's own limit is gone, a program in a terminal can send notifications as fast as it writes, so a pane loop
alone can hold every turn. A budget for programs only would leave that loop unbounded, which breaks P15, an accepted
principle. Budgeting the `uniterm` source as one source would let a program's request flood spend the budget that the
user's own feedback needs. The request lines and the connection refusals are where a program drives the `uniterm` source
with no bound today.

- "Every source, with only the limit notices exempt" was weighed. It bounds the request lines, but one program's flood
  then hides uniterm's replies to the user's own actions.
- Keying terminal notifications by tab instead of by pane was weighed. It would change "Panes, applets, and uniterm
  keep the keys they have today", which the user chose. A loop in one tab costs its sibling tab's info lines only, and
  "Hold a source's newest over-budget post" decides what those lines still raise.

**Decided by:** user, 2026-11-27

### Post a session's lines to its pane's window

Original question: a script's posts go to the active window when its connection first posts. A loop of runs in one tab
can land in several windows, each with its own budget and backlog.

Decision: a source posts to the window that holds its pane. For a terminal session, that is the session's pane. For a
granted connection, it is the granted pane. For a REPL, it is the REPL's pane. The "Pane N" label is then true where it
shows, and one source has one budget in one status center.

Rationale: pane numbers restart in each window, so window B can have its own "Pane 2". A label shown in the wrong
window names a different, real pane, which breaks "Take a script's label from the transport". Panes never move between
windows, so a source's window is fixed for its life. Pane sources already post to their own window's center
(WindowKit/PaneStatusHost.swift:35-39), and the same shell's OSC notifications go there too. The active window with a
ledger across windows would add a component and still mislabel. A budget per window would give one source a budget in
each window.

**Decided by:** proposal-reviewer (autonomous), 2026-11-27

### Hold a source's newest over-budget post

Original question: when a source is over its budget, what does its post do? Every post keeps its history record, per
"Give each source a budget of bar turns".

Decision: an over-budget post is recorded and admitted as today's post is, so a warning or error raises its unseen
signal at once. It replaces its source's waiting entry of its kind, error or non-error, and takes the source's next
turn once the budget allows. The
center's scheduled wake includes the budget's next refill, so a held post on an idle bar still shows. The `post-status`
call succeeds with today's empty reply.

- A held post, like any waiting post, is never replaced by its source's later post of a lower level, per "Share the
  bar fairly between sources". A pane's tabs share one source, so a sibling tab's warning stays waiting when another
  tab's info loop posts, and a user's own refusal reaches the bar.
- A held error is kept apart from the source's non-error posts. A post within the main budget takes its turn while the
  source's error waits for the error budget, and the error shows when that budget refills. A newer error folds into
  the held one.
- A held post does not keep the shown line on the bar past its idle timeout.
- A held entry leaves with its pane, as the pane's other waiting entries do, and leaves when its source ends.

Rationale: the budget meters turns, not posts, so holding the newest gives a loop no more turns than dropping would.
It does make sure a burst's last post shows, at most one refill late, unless the source holds a post of a higher
level. "Quiet" would leave a refused link click in a
sibling tab with no sign at all. "Refuse" would end a progress loop that has no `try` with exit 1, and `busy` promises
that nothing ran, which a recorded post breaks. A reply that says the post was held has no caller that reads it.

**Decided by:** user, 2026-11-27

### Give errors a budget of their own

Original question: should `error` posts take bar turns past the budget?

Decision: errors draw on a separate, smaller budget per source. An error turn spends only the error budget, and other
levels never spend it. Past its error budget, a source's error is held, as any over-budget post is. A source's ceiling
on the bar is then its main budget plus its error budget.

- A source over either budget is in one limited stretch, with one notice and one held-back count across both budgets.
- A held error past the error budget raises its unseen-error mark at once, and shows when the error budget refills.

Rationale: a script picks its own level (ScriptHost/ScriptHost.swift:1053-1058), so exempting errors would let any
script escape the budget by posting at `error`, which breaks ADR-14 P15. Dismissing such an error shows the source's
next one at once (StatusKit/StatusQueue.swift:143-148). Counting errors in the one budget would let a burst of progress
lines spend the turn a real "Failed" needs. A budget of its own keeps both bounds and gives the failure its turn.

**Decided by:** user, 2026-11-27

### Six-turn bucket, refilled every 10 seconds, and a one-turn error bucket

Original question: how many turns, over what window?

Decision: each source's main bucket holds 6 turns and refills one turn every 10 seconds. Its error bucket holds 1 turn
and refills it every 30 seconds. The numbers are constants in `StatusPolicy`, beside the bar's other limits. M2 pins
what they must do:

- A script that posts six lines 2 seconds apart is never limited.
- A source alone on an otherwise idle bar, posting every 5 seconds, holds the bar at most half the time over a long run.
- A source that posts once a second for ten minutes brings one limit notice.

Rationale: a bar turn can stay on screen until the source's next post, and an info line stays up to 5 seconds when
nothing waits. So a budget near the bar's capacity never limits a source that posts every 2 seconds. A small sliding
window limits an ordinary four-step script. A bucket separates the burst a short script needs from the long-run bound:
a long-running source settles to a fresh turn every 10 seconds. The numbers are a judgment, since the repo holds no
script that posts status more than once. Numbers derived from the idle timeout would tie an ADR-14 P15 bound to a UI
polish setting.

**Decided by:** user, 2026-11-27

### Replace libghostty's notification limit with uniterm's budget

Original question: libghostty, at the pinned v1.4.0, drops OSC 9 and OSC 777 notifications before uniterm sees them.
It lets through one a second across the whole app, and drops a repeat of the same text within 5 seconds
(`src/Surface.zig:6612-6647`). uniterm builds one libghostty app for every terminal, so a loop in Pane 1 of one window
can drop a one-off notification from Pane 4 of another, with no history record. This is state carried from one terminal
to the next inside a library.

Decision: a patch beside those in `ThirdParty/ghostty-patches` removes the app-wide limit and the repeat drop that
shares its state. The per-source budget bounds each pane, and the bar's own repeat coalescing takes the place of the
repeat drop. The same patch bounds each terminal's notifications on its own IO thread, before they enter libghostty's
shared app mailbox. Past that bound, a terminal's notifications are dropped and counted, per terminal. The patch sends
the count to uniterm in a count-only message once the bound eases, and when the terminal closes, so every drop is
recorded. Every notification that reaches the bar's queue keeps its history record.

- libghostty's app mailbox holds 64 messages for every terminal, and a full mailbox blocks a terminal's IO thread
  (`src/App.zig:589`, `src/termio/stream_handler.zig:138-149`). It drains in the tick uniterm runs on the main thread
  (TerminalSurface/GhosttyCallbacks.swift:66-72). A bound inside uniterm would come after libghostty's work on the main
  thread. The bound on the IO thread keeps that work bounded, and one terminal's notification flood no longer fills the
  mailbox the others share.
- M1's first check confirms that trace at the pinned commit before the bound is sized.

Rationale: libghostty's limit guards the OS notification center, and uniterm routes notifications to its own bar. One
terminal must not drop another's notifications, or stall them. Keeping the limit per terminal would still drop a
terminal's own notifications with no record. Keeping it as it is leaves hidden state shared between terminals. A bound
in uniterm's callback would leave libghostty's main-thread work per notification unbounded, and the shared mailbox
would still let one terminal's flood stall the others. Amended 2026-11-27; see Decision Log.

**Decided by:** user, 2026-11-27

### Keep a pane line from reading as plain uniterm

Decision: no pane line on the bar reads as plain `uniterm`, whatever the pane's title holds, such as `uniterm` or
`uniterm: Pane 2`.

Rationale: a program can set its tab's title through OSC 2, and the bar drops a pane's ID
(WindowKit/StatusBarContent.swift:113, 132-135). A notification would then read as uniterm's own limit notice. The
code's own rule says only the host reads as plain `uniterm` (:128-131), and "Report a limited source" relies on it.

**Decided by:** user, 2026-11-27

## Design Decisions (Open)

None.

## Risks

- **A legitimate burst gets limited** — likelihood: medium, impact: low.
  Mitigation: the history keeps every post, the newest post past the budget still shows at the next refill unless the
  source holds a post of a higher level, and the limit notice tells the user what happened. A six-step script with
  2-second steps fits the six-turn bucket, and M2 pins that. A source that posts once a second for a long run is still
  limited to a turn every 10 seconds, since no budget that bounds a lone source can let it through.
- **Many sources fill the bar** — likelihood: low, impact: low.
  Accepted: twenty parallel runs in twenty tabs are twenty sources, each within its budget. The fair backlog shows
  each one's newest waiting message of the highest level in turn, and the history keeps all of them. Each source is
  something the user started.
- **A script's posts leave the window the user is in** — likelihood: medium, impact: low.
  Accepted: a run started in window A's pane posts to A's bar while the user works in window B. Pane sources already
  post to their own window. The label names a pane only in the window that holds it.
- **A program opens tabs to get fresh budgets** — likelihood: low, impact: low.
  Accepted: each terminal tab is its own session source with its own budget. Opening a tab needs its own power and
  grant, and each tab is visible to the user. The fair backlog still shares the bar between them.
- **A terminal program shows its pane's lines as `uniterm`** — likelihood: medium, impact: medium.
  Mitigation: a program sets its tab's title to `uniterm` through OSC 2, and the bar drops a pane's ID
  (WindowKit/StatusBarContent.swift:113, 132-135). Its OSC 9 line then reads as uniterm's own limit notice. That breaks
  the code's own rule that only the host reads as plain `uniterm` (:128-131). "Keep a pane line from reading as plain
  uniterm" restores that rule in M1, which "Report a limited source" relies on.
- **The libghostty patch drifts at a version bump** — likelihood: medium, impact: low.
  Mitigation: the build applies every patch in `ThirdParty/ghostty-patches` at the pinned commit
  (scripts/build-ghostty.sh:286-291), and a patch that fails to apply stops the build. The pin moves only deliberately.
  A bump that moves `showDesktopNotification` needs the patch rewritten before it builds. A patch that applied but no
  longer removes the limit would show as dropped notifications, which an M1 check covers.
- **A fast notification sender floods the main thread** — likelihood: medium, impact: medium.
  Mitigation: with libghostty's limit gone, a program can send notifications as fast as it writes. libghostty's app
  mailbox holds 64 messages for every terminal and blocks the sender when full (`src/App.zig:589`,
  `src/termio/stream_handler.zig:138-149`). It drains inside the tick that uniterm runs on the main thread, and
  uniterm then queues one main-thread block per notification (TerminalSurface/GhosttyCallbacks.swift:66-72, 162-166).
  The patch bounds each terminal on its IO thread, before the mailbox, so the main thread's work per terminal stays
  bounded, per ADR-08. The bound is part of the libghostty patch, so the patch-drift risk covers it too.
- **A held post shows late** — likelihood: medium, impact: low.
  Accepted: a held post waits for the next refill, at most 10 seconds, or 30 for an error. The shown line meanwhile
  stays no longer than its idle timeout. Showing late is the cost of always showing a source's last word.
- **Rekeying merges sources the user expects apart** — likelihood: low, impact: low.
  Mitigation: a terminal session is one shell in one tab, and two tabs stay apart. A granted connection and a REPL keep
  keys of their own. A connection with no binding cannot post.
- **The budget depends on how ADR-15 is accepted** — likelihood: low, impact: medium.
  Mitigation: "Budget every source but uniterm's own, and bound the lines a program makes uniterm post" applies one
  rule to every source a program or the user's panes drive, which fits ADR-15 as proposed. The `uniterm` source is
  uniterm's own, not a program's.
- **The `post-status` contract changes for scripts** — likelihood: medium, impact: medium.
  Mitigation: status history is not persisted, and the change alters no stored format, so a redeploy reverts it. The
  `uniterm` command and the app ship together. Other programs send `post-status` too, and ScriptWire is at 0 under
  UTERM-063, so the contract changes in place, and an older program's message is read with its old meaning or refused
  by name. Exec drivers send no status call. The host posts their failures through an applet producer. An over-budget
  post succeeds with today's empty reply, so nothing on the wire changes. What changes is what the user sees: the
  label, the window, and whether a post takes a turn. Amended 2026-11-27; see Decision Log.

## Milestones

### M1: Session-keyed sources, transport labels, and terminal notifications

**Status:** NOT STARTED

- The As built block records a trace of `src/Surface.zig` and the surface mailbox at the pinned commit: how fast
  notifications arrive once libghostty's limit is gone, and whether the mailbox pushes back on a fast sender. The
  per-terminal bound on the IO thread is sized from it, and holds against a terminal program that sends notifications
  as fast as it writes
- One terminal's notification flood never blocks another terminal's output, and never fills the mailbox the others
  share, even while the main thread is stalled, so the bound caps notifications in flight and not only their rate
- A terminal's drop count arrives in a count-only message once its bound eases, and when the terminal closes, even when
  no notification passes after the burst. It is recorded under the pane's source, and is not a new `uniterm` line
- A terminal that floods past its bound until its tab closes, its pane closes, or the app quits still gets its whole
  drop count recorded under the pane's source. libghostty removes a closing surface from its list before it joins the
  IO thread, and drops a mailbox message for a surface no longer listed (`src/apprt/embedded.zig:634-645`,
  `src/App.zig:522-532`). uniterm clears the view's event handler before it frees the surface
  (TerminalSurface/GhosttySurfaceView.swift:259-274). So the close-time count reaches uniterm before both
- Notifications that passed the bound but still sat in the mailbox at close count in the close-time count
- A loop of `uniterm run` posts in one terminal tab is one source on the bar and in the history
- Two terminal tabs in one pane are two sources
- A REPL and a connection the user granted a pane each keep a key and a label of their own, and never post as a terminal
  session or share its budget
- A bound run's post shows the run's label with its session and pane
- A source and its state survive a connection closing within that source, and their state stays bounded in memory
- Sources that outlive their connections never use up the producer limit, so a new session can always post
- A script's label on the bar and in the history comes from the transport. A self-reported name appears only marked
  "(unverified script)"
- Two sources never share a full label in the history, even when a script's name is at its byte cap, and a shortened
  bar label keeps its "(unverified script)" marker
- Panes, applets, and uniterm keep their keys and labels, except that a pane whose bar label would read as plain
  `uniterm` reads with its pane kind instead
- No pane line on the bar reads as plain `uniterm`, whatever the pane's title holds, such as `uniterm` or
  `uniterm: Pane 2`
- Closing a pane drops the waiting lines of its sessions, its REPL, and its grants, as it drops the pane's own
- Two tabs in one pane, and a shell respawned in the same tab, never share a full label in the history
- A one-off notification from one terminal reaches the bar and the history while another terminal sends notifications
  in a loop, in the same window or another
- The same notification text sent twice within 5 seconds reaches the history twice, and the bar coalesces it while
  the first is presented
- Past its bound, a terminal's notifications are dropped and counted for that terminal only, the count reaches the
  history, and the main thread's work per notification stays bounded

### M2: Fair backlog, the budget, and the limit notice

**Status:** NOT STARTED

- With several sources waiting, each source's waiting error and its newest waiting non-error of the highest level get
  turns, in rotation
- An error folds only into an error from the same source
- The `uniterm` source keeps each of its waiting lines, so a limit notice never replaces uniterm's reply to the user's
  own action
- Past the waiting area's bound, other sources' non-error lines leave before uniterm's own, so a waiting "The driver
  did not start" survives twenty looping tabs
- With the waiting area at its bound, no error is dropped, errors from different sources are counted in one tally, and
  memory stays within the existing bounds
- The cross-source error tally posts from the `uniterm` source and carries no other source's label. Tallied errors keep
  their history records and unseen marks, and the oldest waiting errors join the tally first
- A source's posts go to its pane's window, even while another window is active, and a loop of runs in one tab keeps
  one budget whichever window is active
- An error from a source whose pane sits in a background window keeps its unseen mark in that window
- Pane, applet, and script sources are budgeted, and the `uniterm` source is not
- A program that connects with no binding and disconnects in a loop posts at most one "Pending request:" line per 30
  seconds, which counts the requests it folded, while the Pending Requests window lists each live request
- Every refusal that reaches the host's refusal handler shares one bound of one line per 30 seconds, which counts the
  refusals it folded. That covers a program that opens refused connections in a loop, and a bound script that repeats
  a second begin
- The budget never waits on the main thread
- A source within its budget gets its newest waiting non-error of the highest level on the bar in its turn, and its
  waiting error in its error turn
- A post over the budget is held as its source's waiting entry of its kind, raises its unseen mark at once when it is
  a warning or error, and takes the source's next turn when the bucket refills, even on an otherwise idle bar with no
  other post
- Every post keeps its history record, whether it showed, waited, or was replaced while held
- No waiting post, held or within budget, is replaced by its source's later post of a lower level, so a sibling tab's
  waiting warning outlasts another tab's info loop whether or not the pane is over budget
- A source that holds an error still gets its within-budget non-error post's turn, and the error shows when the error
  bucket refills
- A held post never keeps the shown line on the bar past its idle timeout
- A held entry leaves with its pane, and leaves when its source ends
- A newer error on a source's held error folds into it, as errors fold today: the newest error shows with the older
  ones folded, and they count in its "more errors" count, not as held back
- When a source has both a waiting error and a waiting non-error, the order of their turns within one rotation is fixed
  and tested
- A post that was meant for history only, or for attention only, stays that way under the budget, and a post that takes
  no turn spends no budget
- A turn is spent when a post shows on the bar, not when it arrives, so a burst that the fair backlog folds to its
  newest post of the highest level spends one turn
- An error turn spends only its source's error bucket, and progress lines never spend it, so a "Failed" after a burst
  of progress lines gets a turn
- A script that posts six lines 2 seconds apart is never limited, a lone source posting every 5 seconds holds an idle
  bar at most half the time over a long run with today's 5-second idle timeout, and a source posting once a second for
  ten minutes brings one notice
- uniterm posts one notice per limited stretch, from its own source at info, naming the source's full label. For a
  session source, that names the session and its pane, not only the run that tripped the budget
- A limited stretch starts at the source's first post that has to wait, and ends when both its buckets are whole
  again. A source over either budget is in one stretch
- The held-back count, the posts that never got a turn, including those a held post of a higher level turned away, is
  recorded when the stretch ends, or
  when the source ends while limited, even when the source posts nothing more. A session source ends when its session
  ends: its tab or pane closes, or its shell is replaced by a new generation

## Decision Log

- 2026-11-21: Drafted from a discussion of ADR-14's scope during the UTERM-022 run. The user chose a per-source rate
  limit over prompting and over a mute control. Status lines are informational, so prompting would defeat them. Muting
  needs an unmute design, so it is deferred with a revisit hook. The user chose to key sources by requester, to take
  labels from the transport, to keep every post in the history, and to post a notice when a source is limited.
- 2026-11-21: The draft's critique found that UTERM-022's requester keys each `uniterm run` apart, so a bash loop of
  runs stayed many sources. The user chose to key any connection bound to a terminal session by that session, runs
  included. "Key a script's posts by its requester" said a script's source is its requester, "a run, a terminal
  session, or otherwise a connection".
- 2026-11-21 (addition): The critique found the waiting backlog drops other sources' messages whatever the budget. The
  user chose a fair backlog alongside the budget. It brings a cross-source fairness rule into the status queue. "Give each source a budget of bar turns" said the budget "leaves other sources'
  turns alone".
- 2026-11-21: The critique found the Questions header shows an undeclared run's own name. The user chose to show a
  self-reported name only marked "(unverified script)". "Take a script's label from the transport" said "The script's
  chosen begin name is not the label."
- 2026-11-21 (autonomous): The re-check found the fair backlog had no rule at the waiting area's bound. The bound
  stays, the oldest waiting source's non-error message leaves for the history, and errors past it are counted across
  sources. It also found that a granted connection and a REPL are bound in code, so the key now names ancestry with no
  grant. "Which window a session's posts go to" became an open question.
- 2026-11-21 (autonomous): The third pass found the key decision's opening sentence still keyed every bound connection
  by its session, which would let a granted program post as the pane's shell. It now names ancestry, with granted and
  REPL connections keyed apart. This fix was not re-checked, since the critique loop's three passes were spent.
- 2026-11-21 (autonomous): The critique's checks were routed to milestones. These cover state surviving a connection,
  labels that never collide, the no-pane label, the held-back wake, the notice bound, and per-window behavior. The
  open questions gained the attention option, the Janet refusal constraint, the bar's capacity, and the ADR-15 fit.

- 2026-11-21: The user amended ADR-14 with P15 and C1. The open question on whether bounded reach becomes an
  ADR is settled as "Rest the budget on ADR-14 P15 and C1".
- 2026-11-23: From UTERM-056's acceptance. The `post-status` risk said "ScriptWire's hello requires an exact match, per
  ADR-13". That holds only for the command's own messages.
- 2026-11-27: Brought in line with UTERM-063 at the user's direction. The `post-status` risk said "ADR-13 keeps each
  accepted ScriptWire version's meaning for them". At version 0 a change lands in place, and an older program's message
  is read with its old meaning or refused by name.
- 2026-11-27: Review start: 2 milestones, 7 settled decisions, 5 risks, no `**Live after:**` lines or row gates, 5 open
  questions; no out-of-scope statements beyond the deferred mute control. Proposal at commit "Retire :directory from
  list-panes in UTERM-050 and fix the sweep's other slips". Autonomous review, resumed over three unreviewed
  autonomous entries from 2026-11-21.
- 2026-11-27 (autonomous, override pending): Two decisions the user made carry text that autonomous passes wrote on
  2026-11-21. In "Key a script's posts by its terminal session", that is the granted and REPL exception and "through
  its process ancestry". In "Share the bar fairly between sources", it is the rule at the waiting area's bound. The
  text stays, and each decision carries a pending override that asks the user to confirm it. Each settled decision now
  names its decider.
- 2026-11-27 (autonomous): The ADR-13 reference said "ScriptWire's exact-match hello". That no longer holds at version
  0, so it now cites ADR-13 C1.
- 2026-11-27 (autonomous): Premise check. A bash loop of `uniterm run` posts in one tab today gets a new status
  producer per connection (ScriptHost/ScriptHost.swift:1042-1051). Once more than three messages wait, the backlog keeps
  only errors and the newest message (StatusKit/StatusQueue.swift:349-372). Errors fold across sources under the newest
  error's label (:352-362). No rate bound exists on any status post. A program in a terminal pane reaches the bar the
  same way through OSC 9 and OSC 777, posted as the pane (TerminalApplet/TerminalApplet.swift:900-905). The stated
  problem exists.
- 2026-11-27 (autonomous, addition): "Which sources the budget covers" is settled as "Budget every source but uniterm's
  own, and bound the request lines". The budget covers panes, applet producers, and scripts. A program in a terminal
  can hold the bar through OSC notifications, so a budget for programs only would break ADR-14 P15. The addition is a
  bound on the Pending Requests indicator's bar lines, one per interval with a folded count. Converged in 1 pass.
  Keying terminal notifications by tab was weighed and not taken, since it would change a key the user chose to keep.
- 2026-11-27 (autonomous): "Which window a session's posts go to" is settled as "Post a session's lines to its pane's
  window". Pane numbers restart per window, so the active window could show a label that names another real pane.
  Converged in 1 pass.
- 2026-11-27 (autonomous): The critique found that libghostty drops OSC notifications app-wide at one a second, so one
  terminal's loop can drop another's notification with no record. That is hidden state passed between terminals, so
  "Libghostty's shared notification limit" is open for the user, not decided here.
- 2026-11-27 (autonomous, override pending): The critique of "What happens over the budget" ranked holding a source's
  newest post first in both passes. It changes the user's sentence "A post over the budget never takes a turn", so it
  is a pending override on "Give each source a budget of bar turns", not a decision.
- 2026-11-27 (autonomous): "What happens over the budget" is settled under the user's sentence as "Show an over-budget
  post as attention, and retire the source's stale line". Converged in 2 passes on the override above, with this as
  the best option that keeps the sentence. "Refuse" was set aside because `busy` promises that nothing ran.
- 2026-11-27 (autonomous): "Whether errors count against the budget" is settled as "Give errors a budget of their own".
  A script picks its own level, so exempt errors would escape the budget and break ADR-14 P15. Converged in 1 pass.
- 2026-11-27 (autonomous, override pending): "The budget's numbers" is settled as "Six turns and one error turn per
  minute", under the user's sliding window. The critique ranked a token bucket first, since it gives a short script
  its burst and still bounds a long run. That changes "over a sliding window", so it joins the pending override on
  "Give each source a budget of bar turns". Converged in 1 pass on the override, with this as the best option that
  keeps the user's text.
- 2026-11-27 (autonomous, addition): The coherence pass found more program-driven `uniterm` lines with no bound. Each
  refused connection posts a warning, so "Budget every source but uniterm's own" now bounds connection refusals the way
  it bounds request lines, one line per 30 seconds with a folded count. Its title and its claim that request lines were
  the one such path changed with it.
- 2026-11-27 (autonomous): The over-budget retire rule ended a sibling tab's warning when another tab's info loop went
  over budget. It now ends only a line at the same level or lower.
- 2026-11-27 (autonomous): The sliding window has no window that lapses, so "Six turns and one error turn per minute"
  now defines a limited stretch. The notice comes at its start, and the held-back count is recorded at its end.
- 2026-11-27 (autonomous, override pending): `uniterm` is one source, so under the fair backlog a limit notice can
  replace uniterm's reply to the user's own action. Letting the `uniterm` source keep each waiting line changes
  "Share the bar fairly between sources", so it joins that decision's pending override.
- 2026-11-27 (autonomous, addition): A terminal program can title its tab `uniterm` and show its notifications on the
  bar as plain `uniterm`, which breaks the code's own rule. The notice's trust rests on that rule, so M1 restores it and
  the Risks name it. "Libghostty's shared notification limit" gained a per-terminal option and the ingest bound that
  replacing the limit needs. Implementation findings went to M1 and M2 checks. The Risks gained the window move, fresh
  budgets from new tabs, and the title spoof, and lost text about questions now settled.
- 2026-11-27 (autonomous): Risk review. Every risk carries a rating and a mitigation or an acceptance, and none is
  high in both. Nothing is persisted and nothing on the wire changes, so no one-way door or skew rule applies. Added
  the risk that the answers on the pending overrides reshape the budget.
- 2026-11-27 (autonomous): The proposal loop converged in 3 passes: a full pass, a re-check, and a closing re-check
  of the last two text fixes. The pass that bounded connection refusals added a second special case for the rule that
  the `uniterm` source is never budgeted, after the request lines. That growth question goes to the user.
- 2026-11-27 (autonomous): Every code citation in this file was checked against the working tree and holds. One M2
  check said a source over its budget takes no turn, against the error budget's turn for "Failed", and now reads per
  budget. "Libghostty's shared notification limit" names the trace it still needs, and both patch options are marked
  as additions.
- 2026-11-27: Review gate. The user took every recommendation. "Key a script's posts by its terminal session" keeps
  the exception for granted connections and REPLs, and "through its process ancestry". "Share the bar fairly between
  sources" keeps the rule at the waiting area's bound, and the `uniterm` source now keeps each waiting line rather than
  only its newest. "Give each source a budget of bar turns" said "over a sliding window" and "A post over the budget
  never takes a turn". It now refills as a token bucket and holds a source's newest over-budget post. "Show an
  over-budget post as attention, and retire the source's stale line" is replaced by "Hold a source's newest over-budget
  post". "Six turns and one error turn per minute" is replaced by "Six-turn bucket, refilled every 10 seconds, and a
  one-turn error bucket". "Report a limited source" said "When the source's budget window lapses" and "at most one
  notice per budget window". It now counts one notice per limited stretch, which ends when the budget is whole again,
  and posts the notice at info. The user kept the rule that the `uniterm` source is never budgeted, with both 30-second
  folds, which settles the growth question. The user chose errors' own budget, and the fix for a pane titled
  `uniterm` here, an addition. "Libghostty's shared notification limit" is settled as "Replace libghostty's
  notification limit with uniterm's budget", an addition, on the condition that the bounded ingest holds against a
  fast sender. M1's first check traces that. Every pending override is answered.
- 2026-11-27 (addition): The user chose to replace libghostty's app-wide notification limit. It brings in a
  libghostty patch and a bounded notification ingest before the main actor, with M1 checks and two risks.
- 2026-11-27 (addition): The user chose to fix here that a pane titled `uniterm` reads as plain `uniterm` on the bar.
  It brings in "Keep a pane line from reading as plain uniterm" and an M1 check.
- 2026-11-27 (autonomous): The re-check after the gate traced the pinned libghostty. Its app mailbox is one 64-message
  queue shared by every terminal. A terminal's IO thread blocks when it is full, so libghostty pushes back on a fast
  sender and never drops. The mailbox drains in the tick uniterm runs on the main thread, and each notification then
  queues its own main-thread block in uniterm. So no uniterm stage sits before the main actor, as "Replace libghostty's
  notification limit with uniterm's budget" assumed. Where the bound sits, and two gaps in "Hold a source's newest
  over-budget post", are open for the user. Stale text was corrected: the one-a-second claim in "Budget every source
  but uniterm's own", "a fourth patch", the build script's lines, and the missing UTERM-001 impact.
- 2026-11-27: The user settled the four questions the re-check raised. "Hold a source's newest over-budget post" said
  "A held error is never replaced by its source's later non-error post". A held post is now never replaced by a
  later post of a lower level. It said a post "replaces its source's one waiting entry". A source now holds one
  waiting error apart from one waiting non-error, so a post within the main budget takes its turn while an error
  waits. "Share the bar fairly between sources" now lets uniterm's own lines leave last past the waiting area's bound.
- 2026-11-27 (addition): The user chose to bound each terminal's notifications in the libghostty patch, on the
  terminal's IO thread, before the shared app mailbox. "Replace libghostty's notification limit with uniterm's budget"
  said "Notifications cross a bounded ingest before the main actor, as stderr does". The user's condition on that
  choice, that such an ingest would hold against a fast sender, proved false. The trace found no uniterm stage before
  the main actor, since libghostty drains its mailbox in uniterm's main-thread tick. The larger patch also ends the
  shared mailbox's coupling, where one terminal's flood stalled the others.
- 2026-11-27 (autonomous): The re-check of these edits found that a held post of a higher level turns away a later
  lower post, so a burst's last word does not always show. The claims in "Give each source a budget of bar turns",
  "Hold a source's newest over-budget post", and the burst risk now say "unless the source holds a post of a higher
  level". "Report a limited source" said the held-back posts are "those a newer post replaced before they got a turn".
  They are now "those that never got a turn", which counts the posts turned away. Two questions are open for the
  user: whether the level rule covers every waiting post, and how a terminal's drop count reaches uniterm.
- 2026-11-27: The user chose that the level rule covers every waiting post. "Share the bar fairly between sources"
  said it "keeps the newest waiting message of each source". It now keeps the newest of the highest level waiting, and
  no waiting message is replaced by its source's later message of a lower level.
- 2026-11-27 (addition): The user chose that the libghostty patch sends a terminal's drop count on its own, in a
  count-only message once the bound eases and when the terminal closes. "Replace libghostty's notification limit with
  uniterm's budget" said the count "reaches uniterm with the next notification that passes", which lost the count
  when a burst ended past the bound. It brings a new message into the patch and its callback.
- 2026-11-27 (autonomous): The closing re-check found that "Share the bar fairly between sources" kept one message per
  source, while the user's choice of a waiting error apart from a waiting non-error needs two. It now keeps the newest
  waiting error and the newest waiting non-error of the highest level, which joins both choices with no new behavior.
  Lines that said "newest" alone now match. The close-time drop count went to M1 checks, since libghostty and uniterm
  each drop a closing surface's last messages. The proposal loop's pass budget is spent, so this wording fix closes it
  without another pass.
- 2026-11-27: Accepted. No decision earns an ADR.

## References

- [ADR-08](../adr/ADR-08-ui-responsiveness.md): the budget never waits on the main thread
- [ADR-13](../adr/ADR-13-outside-wires-stay-compatible-across-versions.md): C1, a change to a wire at version 0 lands
  in place, and an older program's message is read with its old meaning or refused
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): P13, the requester scope matches what the
  transport established; P15, a program's reach is always bounded; C1, a status line needs no grant
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md) (proposed): a permitted action is not weakened or
  hidden
- [UTERM-022](UTERM-022-questions-applet.md): the requester and the terminal-session key
