# UTERM-067: Stores Keep What They Cannot Read

**Status:** draft
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- ADR-18: the principles this proposal applies. It is proposed, and this proposal is not accepted before it is
- UTERM-004: the controller trust stores, `policy.json` and `files.json`

## Impacts

- UTERM-066 — "Each approval names its artifact kind": driver entries in `policy.json` no longer cut off controller
  approvals in an older build, once this proposal is built.
- UTERM-063 — "Permissions carry no version": it records a permission kind's edition with each approval. An approval at
  an edition this build does not know is an entry this build cannot read, and it follows "One approval is one entry".
- UTERM-004 — "Verified artifact and run binding" and its policy store: a file with an entry this build cannot read
  is no longer moved aside or left untrusted whole. UTERM-004 is implemented, so its text stays, and it gains a
  "Superseded in part by UTERM-067" marker when this proposal is accepted.

## Summary

Every store uniterm keeps for itself follows ADR-18. A build that meets an entry it cannot read keeps using the rest,
keeps the entry unchanged, acts on nothing from it, and shows that it holds one. The controller trust stores change
first. Every other store is checked against ADR-18 and the result recorded.

## Motivation

Today the controller trust store fails whole over one entry. A permission kind this build does not know leaves the
whole file untrusted and unwritable. A selector it does not know moves the whole file aside. Either way, every approval
the user gave is lost in that build, and on a move aside a later save starts a fresh file. The newer build's approvals
then sit only in a numbered aside copy, and only five are kept.

`files.json` was split from `policy.json` to keep older builds working, and UTERM-066 first planned a third file for
driver approvals. ADR-18 removes the need for either split. The user chose to apply it now, while uniterm is pre-v1 and
its formats may still break as often as needed.

## Design Decisions (Settled)

### The trust stores follow ADR-18

Decision: the controller trust stores keep every entry they can read when they meet one they cannot. An entry they
cannot read grants nothing, is written back unchanged on every save, and is counted in the Controllers & Permissions
window.

**Decided by:** user, 2026-11-26

Rationale: ADR-18 P1, P2, P3, and P5.

### Every store is checked

Decision: every store a build keeps for itself is listed and checked against ADR-18. Each store's result is recorded,
with what it would take to meet the ADR. The trust stores are fixed here. A store that falls short is fixed in its own
proposal, or recorded as meeting C1.

**Decided by:** user, 2026-11-26

Rationale: ADR-18 names the stores it knows of today. A list taken from the code finds any it missed.

### One approval is one entry

Decision: an entry in a trust store is one remembered approval: its selector, its artifact kind, and its scopes. An
approval with any part this build cannot read is kept whole, unread, and grants nothing, even for the scopes it can
read.

**Decided by:** new-proposal, 2026-11-26

Rationale: ADR-18 P4. An approval acted on with one of its scopes dropped grants a set of powers the user never
approved as a set. The cost is that an older build gives up the readable scopes of that approval, and asks again for
them.

## Design Decisions (Open)

### Folding `files.json` back into `policy.json`

`files.json` exists only so older builds keep their controller approvals. ADR-18 removes that reason. UTERM-066 already
puts driver approvals in `policy.json`, each naming its artifact kind.

- A. Fold it in. Script-file approvals become entries in `policy.json` with their own artifact kind. A launch of the new
  build moves existing entries over once.
- B. Keep both files. The window already merges them. Nothing moves.

### How the window shows kept entries

ADR-18 P5 asks that the user can see a store holds entries this build cannot read.

- A. A line under the approvals list: "N approvals from a newer version of uniterm are kept, and do not apply here."
- B. A row per kept entry, showing whatever this build can read of it, such as its artifact kind, marked as not
  applying.

## Risks

- **A kept entry the user wants gone survives** — likelihood: low, impact: low. An older build cannot remove what it
  cannot read. Accepted: the user removes it in a build that reads it, and the window says it is there.
- **An approval loses its readable scopes in an older build** — likelihood: medium, impact: low. "One approval is one
  entry" keeps the whole approval unread. Accepted: the older build asks again, and the newer build still holds it.
- **The new reader is the trust boundary** — likelihood: low, impact: high. A reader that half-reads an entry could
  grant from it. Mitigation: M2's checks that a kept entry grants nothing, in every way it can be unreadable.

## Milestones

### M1: Every store checked against ADR-18

**Status:** NOT STARTED

- Every store a build writes for itself and reads back is listed, found from the code
- Each store's result against ADR-18 P1 to P5 and C1 is recorded in the As built block, with what it would take to
  meet the ADR
- Each store that falls short and is not a trust store has a proposal filed or an idea recorded

### M2: The trust stores keep what they cannot read

**Status:** NOT STARTED

- An approval with an unknown permission kind, an unknown selector kind, an unknown artifact kind, or an unknown edition
  grants nothing, and every other approval in the file still applies
- An approval with one unreadable scope grants none of its scopes
- A save from this build writes every kept entry back byte for byte, and a newer build reads it again
- No file is moved aside or left unwritable because of one entry this build cannot read
- A file this build cannot read as a whole, such as one that is not JSON, still grants nothing and is kept aside
- The Controllers & Permissions window shows that kept entries exist
- Two instances of different builds saving the same file keep each other's entries

## Decision Log

- 2026-11-26: Filed from UTERM-066's review. The user chose ADR-18's rule, a new ADR for it, and this proposal to
  apply it to the trust stores and check every other store. The user noted that uniterm's formats may break freely
  before v1, and that ADR-18 binds from v1.

## References

- ADR-06: the layout file's payloads already keep what an older build cannot read
- ADR-14: remembered approvals and their scope
- ADR-18: stored data a build cannot read is kept, and never acted on (proposed)
