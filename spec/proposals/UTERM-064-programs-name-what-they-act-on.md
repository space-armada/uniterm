# UTERM-064: Programs Name What They Act On

**Status:** draft
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- UTERM-063: wires at version 0, so these commands change meaning in place
- UTERM-018: the shared nearest-pane metric that the find query orders by

## Impacts

- UTERM-062 — "What a program addresses in a viewer pane" and "Finding a tab to name" are settled here for every
  applet. UTERM-062 keeps the viewer side: per-tab owners, the viewers' `open`, and their replace commands.
- UTERM-019, UTERM-039 — the browser already requires a tab on every command. Its `open` answers with the tab. The
  shared error and the find query apply to it as to every applet.
- UTERM-054, UTERM-055 — captures name the pane or tab they show.
- ADR-02 — needs the amendment in "Tab identities are never reused".

## Summary

Every program command names the place it acts on, in every applet. Every operation that opens or fills a place tells
the program its identity. A program that needs an identity it does not hold gets one from an alias for its own tab, or
from a query over the tabs it may reach. A command naming a place that is not open, or not the caller's to reach, gets
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

## Design Decisions (Open)

### Targets that pick a place when the command arrives

A script can aim a command at "the nearest pane" of a kind, which uniterm resolves when the command arrives. That is a
selector inside a command, the ambiguity "Finding an identity to name" rules out for tabs.

- A. Remove the nearest-pane target. A script finds the pane with the query, then names it.
- B. Keep it for panes, since a pane is not inside the user's selection, and require a tab beside it.

### The own-tab alias for a caller with no source tab

A controller or a driver runs outside any tab, so it has no source tab.

- A. The alias is refused for such a caller.
- B. The alias names the tab the caller was handed, when exactly one was handed.

## Risks

- **Programs built against an earlier build stop working** — likelihood: high, impact: low.
  Accepted: UTERM-063 sets every wire to version 0, and the only such programs are the user's own.
- **A program loses track of its places** — likelihood: medium, impact: low.
  Mitigation: the find query and the owner field in the pane listing let it find them again.

## Milestones

### M1: Programs name their targets

**Status:** NOT STARTED

- Every program command to a pane or a tab names it, in every applet, and a command naming none is refused
- Every operation that opens or fills a pane or a tab answers with its identity, including `send`. A place made after
  the user acts is named through the operation's handle
- A command naming a place that is not open, or not in the caller's reach, gets one error for both
- The own-tab alias resolves to the caller's source tab. The find query returns identities within the caller's reach,
  filtered by applet, owner, and title, and ordered by first, last, or nearest. The pane listing shows each tab's owner
- Aliases and the find query follow one naming convention, documented with the scripting API
- ADR-02 carries the amendment the user approved, or the milestone waits for it
- Each open decision above is settled

## Decision Log

- 2026-11-26: Drafted from the UTERM-062 review, to hold the rules that reach every applet. The user chose that every
  command names its target, that opens and fills answer with an identity, one error for "not open" and "not yours", an
  own-tab alias and a find query, and one naming convention for aliases.

## References

- ADR-02: pane-tree nodes have stable identities
- [ADR-16](../adr/ADR-16-a-program-can-name-what-it-made.md) (proposed): a program can name what it made
- UTERM-062: "What a program addresses in a viewer pane"
- UTERM-063: wires at version 0
