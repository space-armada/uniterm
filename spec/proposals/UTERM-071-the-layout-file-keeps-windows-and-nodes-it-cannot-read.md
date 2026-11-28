# UTERM-071: The Layout File Keeps the Windows and Nodes It Cannot Read

**Status:** draft
**Created:** 2026-11-27
**Updated:** 2026-11-27

## Dependencies

- ADR-18, whose principles P1, P2, and P4 this proposal applies to the layout file
- UTERM-067, whose M1 found the gaps below and whose M2 builds the reader the trust stores use

## Impacts

- ADR-06 — "A reader that finds a newer schema version keeps the file aside unchanged and starts a default layout." The
  first open decision may narrow that rule.
- UTERM-001 — "What layout persistence restores, and in what format". UTERM-001 is implemented, so its text stays.

## ADR Deviations

None yet. The first open decision may record one under ADR-18 C1.

## Summary

The layout file keeps every window and every node it can read when it meets one it cannot. Today one unreadable node
moves the whole file aside, and every saved window is lost to that build. A part of a node that a build does not hold is
lost on its next save without a sign.

## Motivation

UTERM-067 M1 checked the layout file against ADR-18. Its applet payloads meet every principle. An applet description
that is unknown, newer, or corrupt becomes a placeholder pane, keeps its exact bytes, and writes back unchanged. The
rest of the file falls short in these ways:

- P1: a node with a kind this build does not know makes `LayoutCodec.decode` throw. `readLayout` then moves the whole
  file aside and starts fresh. Every other window, and every other pane in the same window, is gone from that launch.
  A window with no frame or no tree, a node with no valid ID, and a split with one bad weight do the same.
- P1: a window that fails to open at restore leaves the rest of the layout in use. The next save writes only the
  windows that opened, so the failed one survives only in a kept-aside copy.
- P2: the kept-aside copies stop at five. The oldest is deleted when a sixth is made. A newer build's layout, set aside
  once by an older build, is lost after five more such moves.
- P2 and P4: the saved model holds no place for a part it does not read. A pane's control with an unknown access mode or
  driver reads as disconnected. An exec declaration's extra fields are "not read". A window's unknown members are
  dropped. All of it is gone from the next save, and nothing shows it.
- P5: a moved-aside file and a placeholder pane both give a notice. A dropped part gives none.

P3 holds today. Nothing unread becomes a pane, a control, or a running program.

The schema version moves for an additive change today. Version 3 added an exec declaration "since a version 2 reader
would drop it on its next save". That bump is the P4 gap's workaround, and it makes every older build refuse the file.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### What a newer schema version does

Original question: the file's version number moves for any change. A build that finds a newer number moves the whole
file aside, which ADR-18's Consequences say meets P1 only where C1 applies.

Candidates:

- Keep the whole-file rule, and record it as C1. This needs the version to move only when an existing kind changes
  meaning. It reverses ADR-06's "A new node kind is such a change", so it needs an ADR-06 amendment that the user
  decides.
- Drop the whole-file rule. A newer file is read like an older one, and an entry this build cannot read is kept. This
  amends ADR-06's "A reader that finds a newer schema version keeps the file aside unchanged and starts a default
  layout", so the user decides it.
- Keep the rule until version 1, and decide at the freeze. This also leaves ADR-06's sentence as it is until then, and
  needs the user's decision to amend it later.

### The unit a build keeps unread

Original question: which part of the file is one entry the reader may keep unread?

Candidates:

- A window. A window with a node this build cannot read is kept as exact bytes, written back, and shown as an
  unavailable window. Panes inside an unknown node depend on it, so ADR-18 C1 applies to that window only, and the
  other windows still restore.
- A node, with a placeholder where it stood. A pane under an unknown node needs its place in the tree, so a placeholder
  for the node would hold its children as bytes. The tree then holds a node no build can lay out.
- The whole file, as today, recorded as C1. It drops P1 for every window whenever one holds an unknown node.

### What a window that failed to open does

Candidates:

- Keep it as exact bytes in the next save, as a window this build could not restore.
- Keep the copy aside, as today, and write only the windows that opened.

### How a part this build does not hold survives a save

Original question: a pane's control, an exec declaration, and a window carry parts that the model drops.

Candidates:

- Keep the node's exact bytes whenever any part of it is unreadable, as a description does. A pane with an unreadable
  control is kept whole as unread, so ADR-18 P4 holds.
- Hold the unread members of every node and write them back. ADR-18 P4 and ADR-06's Alternatives reject this, so it is
  a deviation from P4 that needs the user's decision.
- Treat the control as inert intent, and record that a lost control is acceptable. It grants nothing, and the user
  enables it again by hand. This drops P2 and P4, so it needs an ADR Deviations entry.

### How many kept-aside copies stay

Candidates:

- Never delete a copy that holds a window no later layout holds. This is the plain ADR-18 P2 reading. A copy also
  names scrollback files that the 30-day sweep deletes, so a copy kept past 30 days restores its tabs without their
  text. UTERM-067 M1 found this, and it belongs to this question.
- Keep the limit of five, and say that a sixth move discards the oldest.
- Delete a copy only when a build that reads it confirms the user's newer layout holds every window in it.

The controller trust store's `policy.json` keeps five aside copies too, for a file this build cannot read as a whole.
UTERM-067 M2 left that limit as it was, so the question covers both stores and one answer settles both. Nothing is
decided here.

## Risks

- **A window kept unread stays for good** — likelihood: medium, impact: low. No build the user runs reads it, so none
  removes it. Mitigation: the window shows as unavailable, with the way out the placeholder pane has today.
- **Keeping bytes holds paths and bookmarks** — likelihood: low, impact: low. A kept window holds the same data the file
  holds today. Accepted: the file is private to the user.

## Milestones

### M1: The reader keeps what it cannot read

**Status:** NOT STARTED

- A node of an unknown kind costs only its window, or only its node, by the decision above. Every other window restores
- A window or node a build cannot read is written back byte for byte on the next save
- A pane's control and an exec declaration with a part this build does not read are kept whole and written back
- The user sees that a window or pane is kept unread
- A file the reader cannot parse as JSON still moves aside whole with a notice
- A kept-aside copy is never deleted while it holds data no later layout holds, or the As built block records the
  decision that keeps the limit

## Decision Log

- 2026-11-27: Filed as a draft from UTERM-067 M1. The check of every store found the layout file's envelope, its unknown
  node kinds, and its dropped control parts short of ADR-18. Nothing is decided.
- 2026-11-27: The question on kept-aside copies now also covers the controller trust store's five copies of
  `policy.json`, which UTERM-067 M2 left as they were. One answer settles both stores. (run best guess)

## References

- ADR-06: the layout file's two layers of versioning
- ADR-18: stored data a build cannot read is kept, and never acted on
- UTERM-067: stores keep what they cannot read
