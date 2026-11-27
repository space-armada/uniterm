# UTERM-064: Programs Name What They Act On

**Status:** accepted
**Created:** 2026-11-26
**Updated:** 2026-11-27

## Dependencies

- UTERM-063: wires at version 0, so these commands change meaning in place
- UTERM-018: the shared nearest-pane metric that the find query orders by
- UTERM-054: the tab scope the find query searches, and the terminal's per-tab owners
- UTERM-063 M2: the refusal by name that every in-place change here relies on
- UTERM-069: the source kinds a program has, which decide what it may name as its own

## Impacts

- UTERM-062 — "What a program addresses in a viewer pane" and "Finding a tab to name" are settled here for every
  applet. UTERM-062 keeps the viewer side: per-tab owners, the viewers' `open`, and their replace commands.
- UTERM-019, UTERM-039 — the browser already requires a tab on every command. Its `open` answers with the tab. The
  shared error and the find query apply to it as to every applet.
- UTERM-054, UTERM-055 — captures name the pane or tab they show. UTERM-055's capture frame loses its omitted `pane`,
  which named the anchor, and its omitted `tab`, which named the selected tab.
- UTERM-028, UTERM-055 — each says it adds nothing to the exec hello. The hello now carries the driver's pane identity,
  and the exec wire carries the find query.
- ADR-02 — needs the amendment in "Tab identities are never reused".
- ADR-16 (proposed) — its Consequences say "Listing places does not say who made them". The owner field in the pane
  listing changes that.
- UTERM-004, UTERM-061 — the `{:nearest kind}` target comes from UTERM-004's nearest rule. UTERM-061 says that if it
  goes, the scripts' caller of the shared metric and its M1 checks go with it. The metric stays, for the find query.
- UTERM-018 — M1's check that "the scripts' nearest-pane rule calls them" now covers the find query's ordering. Its
  M5 is amended: a program's open names its pane, or opens a new pane by placement, and never walks.

## Summary

Every program command names the place it acts on, in every applet. Every operation that opens or fills a place tells
the program its identity. A program that needs an identity it does not hold gets one from an alias for its own tab, from
its exec hello if it is a driver, or from a query over the tabs and panes it may reach. A command naming a place that is not open, or not the caller's to reach, gets
one error for both.

## Motivation

The UTERM-062 review found that a program's command with no tab had to pick a target from the user's selection, or from
hidden state kept for each caller. The user chose that every command names its tab, to remove that ambiguity. ADR-16
records the principle. The rule reaches every applet a program can address, so it lives here, not in one applet's
proposal.

Today the browser requires a tab, the terminal does not, and the viewers have no tabs to name. `send` answers with
nothing, and the viewers' show commands do not say what they filled. The pane listing does not say who owns a tab.

## Design Decisions (Settled)

### Every command names its target

Decision: a program's command names the pane or tab it acts on. A command to an applet with tabs names a tab. uniterm
never fills in the target from the user's focus or selection. A command that names no target is refused. The user
chose this on 2026-11-26.

Rationale: ADR-16 P3. A named target means one thing, whatever the user does meanwhile.

### Every opened or filled place answers with its identity

Decision: every operation through which a program opens a pane or a tab, or puts content into one, answers with that
place's identity. That covers opening a pane, a layout, opening a tab in any applet, `send`, and every applet command
that shows content in a tab. A place that exists only after the user acts, such as picking a file, is named when it
exists, through the operation's handle. The user chose this on 2026-11-26.

Rationale: ADR-16 P1 and P2.

### One error for "not open" and "not yours"

Decision: a command naming a place that is not open, and one naming a place outside the caller's reach, get the same
error. The user chose this on 2026-11-26.

Rationale: a different error would let a program probe which places the user has open.

### Finding an identity to name

Decision: commands take only an identity. A program gets one in two more ways, besides the answers above:

- An alias for the caller's own source tab, such as the terminal tab a script runs in. It is fixed for the caller's
  lifetime.
- A query that returns tab identities, searching only the tabs within the caller's reach, in any applet. It filters by
  applet type, by owner, which is the caller, another program, or the user, and by title. It orders by first, last, or
  nearest by the shared nearest-pane metric. For example: `(first (find-tabs {:applet :browser :mine true :nearest
  true}))`.

The pane listing says who owns each tab. The user chose this on 2026-11-26. (addition)

Rationale: a selector inside a command resolves when the command arrives, after the user may have opened or closed
tabs. Finding first and then naming fixes the target when the program chose it.

### One naming convention for aliases

Decision: every alias, today's and later ones, follows one naming convention. The convention is documented with the
scripting API, not in an ADR. The user chose this on 2026-11-26.

### Tab identities are never reused

Decision: this proposal asks the user to amend ADR-02 so its retirement rule reaches tabs. The amendment applies once
the user approves its text.

> Every place a program can address has an identity, including a tab inside an applet. A tab's identity is never
> reused within a launch, and once the tab is gone it resolves to nothing. A pane-tree node's identity is retired
> across relaunches as well, as above.

Rationale: ADR-02's reason, that a stale reference must fail and never resolve to a different place, holds for tabs.
Tabs need it only within a launch, since no program holds a reference across a relaunch.

### Targets that pick a place when the command arrives

Original question: a script can aim a command at "the nearest pane" of a kind, which uniterm resolves when the command
arrives. That is a selector inside a command, the ambiguity "Finding an identity to name" rules out for tabs.

- A. Remove the nearest-pane target. A script finds the pane with the query, then names it.
- B. Keep it for panes, since a pane is not inside the user's selection, and require a tab beside it.

Decision: no call takes a target that uniterm resolves when the call arrives. The nearest-pane target is removed from
every call, including the calls that make a new place. A script asks the find query for the nearest pane or tab of a
kind, gets its identity, and names that identity in every later call. The identity is opaque to the caller, and it
names the same pane or tab across every invocation until that place closes. The user chose this on 2026-11-26, over
keeping the nearest target on calls that make a new place.

Rationale: in the user's words, the script should never aim a call directly at a nearest pane. The interface is a query
that returns a stable identifier, which the script then uses to refer to the same pane or tab across invocations. Today
a nearest target resolves again on every call, so two calls can land on different panes when the user enables a nearer
one in between.

### Which tabs the find query searches

Original question: The find query searches "the tabs within the caller's reach". ADR-14 P2 defines a run's targets as panes, and UTERM-054
and UTERM-062 define a program's tab scope inside a pane. The pane listing already lists every tab of each pane the
caller may address, with titles hidden when not shown. Which set the query searches, and which power covers it, is not
settled.

- A. The tabs the pane listing shows the caller, under the same power and title rule.
- B. Only the tabs the caller may act on, its tab scope.
- C. A separate power the user grants for the query.

Decision: the find query searches only the tabs the caller may act on: its tab scope, as UTERM-054 and UTERM-062
define it. The user chose this on 2026-11-26.

- The query needs no power beyond the one that lets the caller act on those tabs.
- A query that must see every tab, such as a later administrative mode, is a separate call with its own power. It
  never widens this one.

Rationale: in the user's words, a result the caller's next command would always refuse is mostly useless. Every
result is something the program can name in its next call. The pane listing keeps showing what the caller sees, and
the query returns what it may name.

### The own-tab alias for a caller with no source tab

Original question: UTERM-069 gives every program a source of one kind: a tab, for a script or a controller started in a terminal tab; a
pane, for an exec driver attached to a pane; or external, for a program uniterm cannot trace to a tab. Grant Access,
which bound an outside program to a pane, is removed. A tab source has a source tab. An exec driver has a source pane
and no source tab, and today its command with no `pane` field acts on its own pane, while the exec hello does not tell
it its pane's ID. An external program has no place of its own until it opens one, and opens its first pane through
UTERM-069's target form for its own window.

- A. The own-tab alias is refused for a caller with no source tab, and an exec driver has no way to name its pane.
- B. An own-pane alias beside the own-tab alias names a driver's pane, fixed for the driver's lifetime.
- C. The exec hello carries the identity of the driver's pane, which the driver names like any other identity. No
  alias is added. The own-tab alias is refused, by name, for a driver and for an external program.

Decision: D, added by the review. The exec hello carries the identity of the driver's pane, and the driver names it
like any other identity. No alias is added. The exec wire carries the find query, limited to the driver's reach, so a
driver finds the tabs of its own pane, including ones it did not open. A driver's `command` and `layout` frames name
their pane by that identity: a `command` frame names it as `paneCommand` already does, and a frame that names none is
refused, while a `layout` frame's body already places the anchor by it. The own-tab alias
is refused, by name, for a driver and for an external program. (autonomous)

- An external program has no place of its own until it opens one. It names its own window only through UTERM-069's
  target form for opening a pane, and otherwise works from the identities its opens answer and the find query.

Rationale: a driver's pane never changes for the driver's life, since a driver ends when its pane closes, so an
identity in the hello is as fixed as an alias and can be compared with the identities replies and find results return.
Today a driver cannot make its first layout at all: the layout must place the driver's pane by its number
(`PaneTree.swift:527`), and nothing tells the driver that number (`ExecDriverChannel.swift:164`). A driver started on
a pane the user already opened a file in must name that file's tab, which only a find on the exec wire gives it.
Refusing an alias leaves both gaps open, and UTERM-055's capture frame, which names the anchor by leaving `pane` out,
would contradict "Every command names its target". Converged in 1 pass.

### How a program gets a pane's identity

Original question: The find query returns tab identities. A program also needs a pane's identity, to open a tab in a pane, to open a pane
beside one, or to lay out from one. Identities are opaque, so a program cannot derive a pane's identity from a tab's.

- A. Each find result names a tab and the pane that holds it. Every applet publishes at least one tab, so every pane a
  caller may reach is found through one of its tabs.
- B. A separate pane query, with the same filters and scope as the tab query.

Decision: F, added by the review. The find query returns panes as well as tabs. A tab result names the tab and the
pane that holds it. A pane result searches the panes the caller may act on at pane level: its source pane and the
members of groups it owns, while remote-controlled. Pane results are ordered by the same nearest-pane metric. They
include a pane where none of the tabs are the caller's, so the caller can still open a tab there or lay out from it.
(autonomous)

Rationale: a pane can be one the caller may open a tab in while none of its tabs are in the caller's tab scope, such as
a terminal pane the user enabled for a controller, which holds only the user's tabs under UTERM-054. A query that found
panes only through tabs would miss it, and a nearest search would return a farther pane or nothing, where today's
nearest target picked it. A separate pane query with the tab query's scope would miss the same panes. Converged in 1
pass.

### A pane-level operation names only its pane

Original question, added by the review: an operation on a whole pane, such as a pane capture, acts on a pane whose
applet has tabs. Must it name a tab too?

Decision: an operation on a whole pane names only the pane, and one on a tab names the tab. A pane capture shows the
pane as the user sees it, its selected tab included, under UTERM-054's tab scope. (autonomous)

Rationale: the pane is the target, and what it shows is not a choice the program makes. Requiring a tab would make a
program name the user's selection, which can change between a listing and the operation, and a driver has no listing
to read it from.

- The pane-level operations are a pane capture (`"of":"pane"`), a layout, opening a tab in a pane, and opening a pane
  beside one. Every applet command to an applet with tabs still names a tab.

### How these wires change across versions

Original question, added by the review: this proposal changes ScriptWire, the exec wire, and the applet command
schemas, each deployed apart from the app.

Decision: every change lands in place at version 0, after UTERM-063 M2, and each older program is refused by name,
never misread. (autonomous)

- An old driver's `command` with no `pane`, or a capture with no `pane` or `tab`, is refused by name: an omission whose
  meaning ends is refused, as UTERM-063 allows.
- A new app's hello with the added pane identity shows an old driver only a field it does not know.
- An old program's `{:nearest kind}` target, ScriptWire target tag 1, is refused by name, and tag 1 joins UTERM-063's
  table of retired names, so no later form reuses it.
- The opaque identity rides on a new target form, and on new message tags wherever a reference appears in a reply.
  Today's tab-reference form, target tag 0 with its window, pane, and tab numbers, joins the retired names and is
  refused by name, so an old program's numbers are never read as an identity. Reply records do not reuse the `window`,
  `pane`, or `tab` keys with a new meaning.
- The same holds in JSON bodies on both wires: layout bodies, and the exec `command` and capture frames. An identity
  there takes a form that cannot be read as today's whole numbers, under a new key, and today's numeric `pane` and
  `window` keys in those bodies are refused by name. Exec replies follow the same rule for their keys.

Rationale: UTERM-063 puts every external wire at 0 with this rule, so no version negotiation is needed.

## Design Decisions (Open)

None.

## Risks

- **Programs built against an earlier build stop working** — likelihood: high, impact: low.
  Accepted: UTERM-063 sets every wire to version 0, and the only such programs are the user's own.
- **UTERM-018 M5 picks a pane when a script's open arrives** — likelihood: high, impact: medium.
  UTERM-018, accepted and unbuilt, walks a script's file or URL open to the nearest capable existing pane when the call
  arrives. That is the selector "Targets that pick a place when the command arrives" removes. Mitigation: UTERM-018 M5
  is amended so a program's open names its pane, or opens a new pane by placement, and never walks. The user's own opens
  keep the walk. The user chose this at the review gate.
- **A program loses track of its places** — likelihood: medium, impact: low.
  Mitigation: the find query and the owner field in the pane listing let it find them again.

## Milestones

### M1: Programs name their targets

**Status:** NOT STARTED

- Every program command to a pane or a tab names it, in every applet, and a command naming none is refused
- Every operation that opens or fills a pane or a tab answers with its identity, including `send`. A place made after
  the user acts is named through the operation's handle
- A command naming a place that is not open, or not in the caller's reach, gets one error for both
- The own-tab alias resolves to a tab source's tab, and is refused by name for an exec driver and an external program
- The exec hello carries the driver's pane identity, and a driver's first layout places its pane by it. A `command` or
  `layout` frame that names no pane is refused
- The find query returns tab results, each naming its tab and pane, within the caller's tab scope, and pane results
  within the caller's pane reach, without repeating a pane once per tab. It filters by applet, owner, and title, and
  orders by first, last, or nearest. A pane's owner is its group's owner, and its title follows the listing's rule.
  Nearest ordering uses UTERM-018's shared metric
- The exec wire carries the find query, limited to the driver's reach
- The pane listing shows each tab's owner
- The scripting API documents the alias naming convention, and every alias and the find query follow it
- Identities are opaque: a program cannot read a window or a pane from a tab's identity, or build one from parts
- `{:nearest kind}` and ScriptWire target tag 1 are refused by name, tag 1 is in UTERM-063's retired names, and the
  repository's Janet fixtures that used it are rewritten
- A retired tab identity resolves to nothing, in ScriptWire's form and the exec form, for viewer tabs as for others
- `open-pane` and layout answers name each new pane and its first tab, and `open-form` answers with its pane
- Every driver and fixture in the repository names its pane, `Tests/ExecTestSupport/Fixtures/driver.pl` included
- Calls that act on no pane, such as status posts and the clipboard, name no target
- On the exec wire, find results use the exec forms of identities, so they compare with the hello's pane identity
- A driver's `command` naming its own pane keeps own-pane authority, including after Disconnect and Revoke
- The find query's nearest ordering measures from the caller's source pane, and is refused by name for a caller with
  no source pane, such as an external program, or whose source pane or tab is gone. Such a caller orders by first or
  last instead
- A window is named by an opaque identity too, `list-panes` included, and an old program's window number is refused by
  name
- A layout body or exec frame that carries today's numeric `pane` or `window` key is refused by name
- A pane capture (`"of":"pane"`) names a pane and no tab, and one that names a tab is refused by name. A content or
  full-page capture that names no tab is refused by name
- A driver's `command` naming its own pane carries `applet` and `schema`, and a value that differs from the hello's is
  refused by name
- The title filter matches only titles the caller may see
- A driver's pane results include its own pane after Disconnect, as its tab results do
- A disconnected pane the caller may address keeps its own refusal text, since it reveals nothing the caller lacks
- ADR-02 carries the amendment the user approved, or the milestone waits for it

## Decision Log

- 2026-11-26: Drafted from the UTERM-062 review, to hold the rules that reach every applet. The user chose that every
  command names its target, that opens and fills answer with an identity, one error for "not open" and "not yours", an
  own-tab alias and a find query, and one naming convention for aliases.
- 2026-11-26: Review start: 1 milestone, 6 settled decisions, 2 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the draft, as committed in "Draft UTERM-063 and
  UTERM-064 from the UTERM-062 review".
- 2026-11-26: Targets that pick a place when the command arrives: the nearest-pane target is removed from every call. A
  script queries for the nearest pane or tab and names the opaque identity it gets back. The user chose this.
- 2026-11-26: Which tabs the find query searches: only the tabs the caller may act on, its tab scope. A query that
  sees every tab would be a separate call with its own power. The user chose this.
- 2026-11-27: The own-tab alias for a caller with no source tab: no alias for a driver. The exec hello carries its
  pane's identity, the exec wire carries the find query, and a driver's frames name their pane. Restated the question
  for UTERM-069's source kinds, which removed Grant Access. (autonomous, addition: the find query on the exec wire)
- 2026-11-27: How a program gets a pane's identity: the find query returns panes as well as tabs, with pane results over
  the caller's pane reach. (autonomous, addition: pane results, within the find query the user added)
- 2026-11-27: Coherence pass. Added "A pane-level operation names only its pane" and "How these wires change across
  versions". Made opaque identities a checked contract, since a tab reference exposes its window and pane today. A
  driver's `layout` frame places its anchor in its body, with no separate pane field. Fixed the Summary, Dependencies,
  and Impacts, added the UTERM-018 risk, tagged the additions, and routed fifteen checks to M1. (autonomous)
- 2026-11-27: Re-check fixes. Opaque identities ride on a new target form, and today's tab-reference form is retired
  and refused by name, so an old program's numbers are never read as an identity. Nearest ordering is refused for a
  caller with no source pane rather than measured from per-program state. Routed checks on capture forms and a driver's
  own-pane command fields. (autonomous)
- 2026-11-27: Closing re-check fix. Opaque identities in JSON bodies, layout bodies and exec frames, use a form that
  cannot be read as today's numbers, under a new key, and today's numeric keys there are refused by name. Windows take
  an opaque identity too. No critic pass has checked this fix, since the loop reached its pass limit. (autonomous)
- 2026-11-27: Review gate: kept all. UTERM-018 M5 is amended so a program's open names its pane or opens a new one,
  never walking on arrival. The user chose this. The exec hello's pane identity, the find query on the exec wire, and
  its pane results are kept.
- 2026-11-27: Accepted after its review. ADR candidate: a program names every place by an opaque identity it was given,
  never built from parts. Declined: ADR-16 covers naming places, and ADR-02's amendment covers reuse. The ADR-02
  amendment text still waits for the user's approval, and M1 waits with it.

## References

- ADR-02: pane-tree nodes have stable identities
- [ADR-16](../adr/ADR-16-a-program-can-name-what-it-made.md) (proposed): a program can name what it made
- UTERM-062: "What a program addresses in a viewer pane"
- UTERM-063: wires at version 0
