# UTERM-070: A Viewer Keeps Its File When the New One Fails to Load

**Status:** draft
**Created:** 2026-11-27
**Updated:** 2026-11-27

## Dependencies

- UTERM-015, whose source-replacing contract promises that a failed swap keeps the pane's old source
- UTERM-062, which decides what a user's open and a program's replace do once a viewer holds several tabs

## Impacts

- UTERM-062 — "Every user open adds a tab" and "What a program's open does". Once a user's open adds a tab, the user has
  no replace inside a tab, and the gap below can only be reached by a program's replace into a tab it names. Whether
  this proposal is needed at all depends on those two decisions. See the first open decision.
- UTERM-018 — its routed opens call the same source-replacing path until UTERM-062 turns them into tabs.

## ADR Deviations

None.

## Summary

A viewer pane keeps its old file when a chosen replacement passes the open check and then fails its full load. Today
the pane shows the failure and its saved description names the bad file, so a relaunch restores the bad file too.

## Motivation

`SourceReplacing` promises that a failed swap keeps the pane's old source. UTERM-015 M3 says the same. No viewer kept
that promise. Each viewer wrote the new path into its description before its asynchronous load began, and none could
throw.

The first fix landed as the commit "Keep a pane's file when Open in This Pane cannot read the new one". It adds a
`checkSource` call to the protocol. The pane's Open and a drop run it before the swap. Each viewer's check reads the
file far enough to find the failures it can, then drops what it read. A file that fails the check leaves the pane alone.

A file that passes the check and fails the load still replaces the pane's file. The checks stop short of the full load
on purpose, since a full load held twice is costly:

- The image viewer's check finds and opens the file but never decodes it. On 2026-11-27 a scratch test opened a good
  PNG, then swapped in a file with a PNG signature and 64 bytes of garbage. The pane showed the decode failure, took the
  title `broken.png`, and saved that path. The old image was gone.
- The text viewer's check runs the PDF and Markdown readers, and only opens and sizes an RTF or Word file. The rest of
  that load was traced, not run.
- The data viewer's check stops at the first rows. A parse error past them was traced, not run.
- The map viewer's check reads the whole document, so no gap is known there. It reads the file twice.

The first fix kept the synchronous replace. A script's `send` and a routed open still replace at once, since an async
swap for them changes the script contract. The user had chosen an `async throws` swap for every caller. The check landed
in its place.

The bug is `20261127-chosen-open-check-misses-full-load-failures`.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### Whether this proposal is needed once UTERM-062 lands

UTERM-062 is accepted and not started. Its summary says every open the user makes into a viewer pane adds a tab. Its
"What a program's open does" says `show`, `show-markdown`, and `send` replace the tab they name, and a new `open`
command adds one. After it lands, a user's open can no longer replace a file. A failed open lands in a new tab, and the
old tab is untouched.

The gap that stays is a program's replace into a named tab, and the interval before UTERM-062 ships. Whether a program's
replace should keep the old content on a failed load was not decided there. Whether UTERM-062's tab open should drop a
tab whose load failed was not either.

Candidates:

- Add no code. UTERM-062 ends the user's replace, and a program's replace shows its failure in the tab it named, as a
  replace does today. This is the plain behavior. The first fix's checks then have little left to guard, and the
  interval before UTERM-062 keeps the gap.
- Settle the interval and the program's replace here. The other decisions below apply.
- Fold both into UTERM-062 as amendments. This adds scope to that proposal, which an addition label would carry.

### What a failed load does to the file a pane or tab already shows

Original question: when a chosen or program-sent file passes the open check and fails its load, does the pane keep its
old file?

Candidates:

- The pane keeps the old file. The viewer loads the new file aside and swaps its description and view once the load
  succeeds. A failure posts a warning and changes nothing else. This restores the contract UTERM-015 states. It is the
  complete fix. The file is read once, and the check has nothing left to miss.
- The pane shows the failure, as today. The first fix's checks stay as they are, and the contract text is narrowed to
  what the checks can see. This rewrites the docs to match the code, and it withdraws the guarantee for every failure
  the checks cannot see.

### Which callers keep the old file

Original question: a user's Open and a drop keep it today for failures the check sees. A script's `send` and a routed
open replace at once. Does the rule hold for every caller?

Candidates:

- Every caller keeps the old file. One rule, and the swap is asynchronous for all of them. A script's `send` then waits
  for the load, which changes the script contract. UTERM-063 holds every wire at version 0, so the contract changes in
  place.
- A user's open keeps it, and a program's replace does not. A program asked for a replace and learns of the result from
  its reply. The contract stays synchronous. A pane keeps its file for a user's open and loses it for a program's. Whether
  a program learns of a failed load from its reply was not checked.

### How each viewer holds two loads

Only if a candidate above loads aside. The data viewer's session and the image viewer's helper each hold one source
today. The text viewer's PDF and Markdown readers and the map viewer's document read are already separable. Candidates
include a second session, a probe that runs the real loader to a settled result, and a rollback that restores the old
record and reloads it. A rollback re-reads the old file and drops its sort, filter, and scroll.

## Risks

- **A second load held at once raises a viewer's peak memory** — likelihood: medium, impact: medium.
  The data viewer's budget covers one load, and the image helper holds one source. A large file loaded aside doubles the
  peak until the swap lands.
  Mitigation: the aside load takes its own budget lease and releases it when it fails. A test loads a file near the
  budget aside and checks that the old table stays.
- **An asynchronous swap for program callers changes what `send` waits for** — likelihood: medium, impact: medium.
  A script that sends a file and reads the pane at once could read the old file.
  Mitigation: the swap settles before `send` replies, and a test pins it. UTERM-063 holds the wire at version 0, so no
  skew applies.

## Milestones

Written once the open decisions settle.

## Decision Log

- 2026-11-27: Filed as a draft from bug `20261127-chosen-open-check-misses-full-load-failures`. The triage reproduced
  the image viewer's case and found two non-trivial decisions: which callers keep the old file, and how each viewer
  holds two loads. The user chose a proposal over fixing now or amending the bug.
- 2026-11-27: Drafting read UTERM-062 after that choice. It shows that a user's open will add a tab and never replace
  one. The first open decision asks whether this proposal is needed at all.

## References

- UTERM-015: the source-replacing contract
- UTERM-062: tabs in the viewers
- UTERM-063: every wire at version 0
- Bug `20261126-failed-pane-open-drops-the-old-source`, fixed in part
- Bug `20261127-chosen-open-check-misses-full-load-failures`
