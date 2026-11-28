# UTERM-047: Rate-Limit Status Posts per Source

**Status:** draft
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
- UTERM-003 — supersedes in part. The `post-status` call: a script's label no longer comes from its own begin name, and
  a post over the budget behaves per "What happens over the budget".
- UTERM-022 — "What a requester is": status reuses its terminal-session key, but keys a bound run by its session where
  the Questions pane keys each run apart. The Questions pane is unchanged.

## Summary

The status bar learns who posted each message from the transport, and shares its turns fairly between sources. A
script's posts are keyed by the terminal session it runs in, so a loop of runs in one tab is one source. Each source
has a budget of bar turns, and uniterm posts its own line when it limits one.

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
session is the unit the user sees: one shell in one tab.

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

### Share the bar fairly between sources

Decision: the waiting backlog is fair across sources. It keeps the newest waiting message of each source, and turns on
the bar rotate between sources. Errors fold only into an error from the same source.

- The waiting area keeps its existing count and byte bounds. Past a bound, the oldest waiting source's non-error message
  leaves the bar's queue and stays in the history. Errors past the bound are not dropped. They are counted in one
  tally across sources, which uniterm shows as a single line from its own source.
- A lone source that posts several lines within one dwell now shows only its newest. Today up to three waiting
  messages all get turns.

Rationale: the bar is shared attention. A source-blind backlog lets one chatty source push every other source's message
off the bar, even within any time budget.

### Give each source a budget of bar turns

Decision: each source has a budget of turns on the bar over a sliding window. A post within the budget takes its turn
as today, subject to the fair backlog. A post over the budget never takes a turn. Every post, within or over the
budget, keeps its history record, subject to the existing retention caps.

- The budget runs on the main-actor status center and never waits, per ADR-08.

Rationale: fairness alone leaves a lone chatty source holding an otherwise idle bar for as long as it runs. A budget
bounds that in time. A prompt is the wrong tool: a status line is informational, and asking before each one would
defeat it.

### Report a limited source

Decision: when uniterm starts limiting a source, it posts its own line from the `uniterm` source. The line names the
source by its full transport label. When the source's budget window lapses, or the source ends while limited, the
history records how many posts were held back.

- The notice is bounded. A limited source produces at most one notice per budget window.
- uniterm's own notices are never limited by the budget. That rule keeps a notice from limiting itself in a loop.

Rationale: the user should know why a source went quiet. The line comes from uniterm's own source, so a script cannot
fake it.

### Rest the budget on ADR-14 P15 and C1

Decision: the budget is this proposal's bound under ADR-14 P15, that a program's reach is always bounded. A status line
needs no grant under ADR-14 C1, since it only shows the user something.

Rationale: the user amended ADR-14 to state the principle, so this proposal cites it rather than standing alone.

### Defer a "mute this source" control

Decision: no control to mute a source. Muting needs a way to list and remove mutes later, and the fair backlog and the
per-source budget bound the problem for now.

**Revisit:** when the user reports a source the budget leaves too loud, or asks to silence one source entirely; file a
follow-up proposal for muting and unmuting.

## Design Decisions (Open)

### What happens over the budget

Original question: when a source is over its budget, what does its post do? Every post keeps its history record, per
"Give each source a budget of bar turns".

- **History only, quiet.** The post is recorded with no turn and no unseen signal. The call succeeds. The script
  cannot tell it was limited.
- **History with attention.** The post is recorded with no turn, and it raises the unseen signal, as the existing
  attention delivery does. The call succeeds. A real problem still shows in the signal. A nagging source still raises
  it. The signal counts only warnings and errors, so an info progress loop behaves as "History only, quiet".
- **Record, then refuse.** The post is recorded, and the call fails as `busy`.
  - Leaves undone: Janet's `post-status` raises on any failure, and an uncaught error ends `uniterm run` with exit 1.
    So a progress loop with no `try` dies at its first post over the budget. The failure kind does not reach the
    script either, only the message text. This breaks existing scripts.

ADR-15, which is proposed, says a permitted action is not weakened, delayed, or hidden. Every option hides an
over-budget post from the bar. That fits ADR-15 only as a rule for every source. See "Which sources the budget covers".

### Whether errors count against the budget

Original question: should `error` posts take bar turns past the budget?

- **Exempt.** Errors keep today's never-dropped rule, folded within their own source. A real failure is never silenced.
  A script can still nag with errors.
- **Counted, with attention.** Errors count against the budget. Past it, they take no turn but raise the unseen-error
  signal.
- **Own budget.** Errors get a separate, smaller budget.

### The budget's numbers

Original question: how many turns, over what window?

At the bar's minimum dwell of 1.5 seconds, the bar shows at most about 6.7 turns in 10 seconds across all sources. The
fair backlog shares those turns, so the budget bounds one source alone on the bar.

- A fixed number per source, such as 5 turns in 10 seconds.
- A share of the bar's capacity, so a source alone on the bar never holds more than a set fraction of the window.

### Which window a session's posts go to

Original question: a script's posts go to the active window when its connection first posts. A loop of runs in one tab
can land in several windows, each with its own budget and backlog.

- **The pane's window.** A session source posts to the window that holds its terminal pane. The "Pane N" label is then
  true where it shows, and one source has one budget.
- **The active window, as today.** The source's budget is shared across windows by its key, and the label names a pane
  that may sit in another window. Each window has its own status center, so the budget would need a ledger across
  windows.

### Which sources the budget covers

Original question: does the budget cover every source, or scripts only? The fair backlog covers every source either
way.

- **Every source.** Panes, applets, and scripts alike, apart from uniterm's own notices. One rule for every source, as
  ADR-15 asks.
- **Programs only.** Scripts and applets.
  - Leaves undone: ADR-15, if accepted, treats a rule for programs only as a special case. This option would need an
    ADR Deviations entry, and the proposal would state why programs are treated apart.

## Risks

- **A legitimate burst gets limited** — likelihood: medium, impact: low.
  Mitigation: the history keeps every post, and the limit notice tells the user what happened. The budget's numbers
  are an open question, sized so a normal progress script stays inside it.
- **Many sources fill the bar** — likelihood: low, impact: low.
  Accepted: twenty parallel runs in twenty tabs are twenty sources, each within its budget. The fair backlog shows
  each one's newest message in turn, and the history keeps all of them. Each source is something the user started.
- **Rekeying merges sources the user expects apart** — likelihood: low, impact: low.
  Mitigation: a terminal session is one shell in one tab, and two tabs stay apart. A granted connection and a REPL keep
  keys of their own. A connection with no binding cannot post.
- **The budget depends on how ADR-15 is accepted** — likelihood: medium, impact: medium.
  Mitigation: "Which sources the budget covers" names the option that fits ADR-15, and the one that would need a
  deviation.
- **The `post-status` contract changes for scripts** — likelihood: medium, impact: medium.
  Mitigation: status history is not persisted, and the change alters no stored format, so a redeploy reverts it. The
  `uniterm` command and the app ship together. Other programs send `post-status` too, and ScriptWire is at 0 under UTERM-063, so
  the contract changes in place, and an older program's message is read with its old meaning or refused by name. `busy`
  already exists on the wire. Exec drivers send no status call. The host posts their failures through an applet
  producer. Only a refusal from `post-status`, if "What happens over the budget" picks one, would become published
  script behavior, and its leaves-undone line says what it breaks.

## Milestones

### M1: Session-keyed sources and transport labels

**Status:** NOT STARTED

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
- Panes, applets, and uniterm keep their keys and labels

### M2: Fair backlog, the budget, and the limit notice

**Status:** NOT STARTED

- With several sources waiting, each source's newest message gets a turn, in rotation
- An error folds only into an error from the same source
- A source within its budget gets its newest waiting message on the bar in its turn
- With the waiting area at its bound, no error is dropped, errors from different sources are counted in one tally, and
  memory stays within the existing bounds
- A source over its budget takes no more bar turns, and every post keeps its history record
- uniterm posts at most one notice per limited source per budget window, from its own source, naming the source's full
  label, which for a bound run includes its session and pane, and each notice reaches the bar or the history as the
  decision states
- The cross-source error tally posts from the `uniterm` source and carries no other source's label. Tallied errors keep
  their history records and unseen marks, and the oldest waiting errors join the tally first
- The held-back count is recorded when the source falls back under its budget or ends while limited, even when the
  source posts nothing more
- A session's posts go to the window that "Which window a session's posts go to" settles
- The budget never waits on the main thread
- Over-budget posts and errors behave as "What happens over the budget" and "Whether errors count against the budget"
  settle

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

## References

- [ADR-08](../adr/ADR-08-ui-responsiveness.md): the budget never waits on the main thread
- [ADR-13](../adr/ADR-13-outside-wires-stay-compatible-across-versions.md): ScriptWire's exact-match hello
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): P13, the requester scope matches what the
  transport established; P15, a program's reach is always bounded; C1, a status line needs no grant
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md) (proposed): a permitted action is not weakened or
  hidden
- [UTERM-022](UTERM-022-questions-applet.md): the requester and the terminal-session key
