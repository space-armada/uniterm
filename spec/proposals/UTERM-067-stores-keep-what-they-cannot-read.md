# UTERM-067: Stores Keep What They Cannot Read

**Status:** designing
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- ADR-18: the principles this proposal applies. It is proposed, and this proposal is not accepted before it is
- UTERM-004: the controller trust stores, `policy.json` and `files.json`

## Impacts

- UTERM-066 — "Each approval names its artifact kind" and "Version skew": driver entries in `policy.json` no longer
  cut off controller approvals in an older build that has this proposal's reader. A build from before this proposal
  reads the new file as newer, or moves aside one it cannot parse whole, per "Version skew". UTERM-066's "Version skew" bullet on the policy store is amended to
  match when this proposal is accepted.
- UTERM-063 — "Permissions carry no version": it records a permission kind's edition with each approval. An approval at
  an edition this build does not know is an entry this build cannot read, and it follows "One approval is one entry".
- UTERM-063 — "The controller policy file at the reset" and its M1 check "A policy file written before the reset is
  set aside with a notice": the reset tells a pre-reset file apart only by scopes at a version this build does not
  know. Under this proposal such scopes would be entries kept unread. "Old trust files are set aside" tells the file
  apart by its format number instead: whichever of UTERM-063 M1 and this proposal lands second moves it. UTERM-063's
  M1 check is amended to match when this proposal is accepted.
- UTERM-004 — "Verified artifact and run binding" and its policy store: a file with an entry this build cannot read
  is no longer moved aside or left untrusted whole. UTERM-004 is implemented, so its text stays, and it gains a
  "Superseded in part by UTERM-067" marker when this proposal is accepted.
- UTERM-021 — "Trust records for files", through "One store holds every approval": the split that keeps package and
  script-file stores from being read as each other's ends. Entries name their artifact kind instead. UTERM-021 is implemented, so it gains a "Superseded in
  part by UTERM-067" marker when this proposal is accepted.
- UTERM-032 — "One store holds every approval": its input-folder approvals live in `policy.json`, and its third store
  is never built. Its rules that span stores (one store per selector, revoke across both, the move order, the union of
  a selector in both) and the risks they carry no longer apply. UTERM-032 is accepted and not built, so its "The stored
  approval" decision and its M1 checks are amended to match when this proposal is accepted.
- UTERM-024 — "Stores that older builds read", and UTERM-026's matching risk and kind decision: they rely on
  `policy.json` never holding a script-only kind, so package approvals keep working in older builds. Under "One store
  holds every approval" that stops holding. uniterm is pre-v1, so the older-build reasoning no longer weighs, and their
  text is amended to say so when this proposal is accepted.

## Summary

Every store uniterm keeps for itself follows ADR-18. A build that meets an entry it cannot read keeps using the rest,
keeps the entry unchanged, acts on nothing from it, and shows that it holds one. The controller trust stores change
first. Every other store is checked against ADR-18 and the result recorded.

## Motivation

Today the controller trust store fails whole over one entry. A permission kind this build does not know leaves the
whole file untrusted and unwritable. A selector it does not know moves the whole file aside. Either way, every approval
the user gave is lost in that build, and on a move aside a later save starts a fresh file. The newer build's approvals
then sit only in a numbered aside copy, and only five are kept.

`files.json` was split from `policy.json` to keep older builds working. UTERM-066 first planned another file for driver
approvals, and UTERM-032 plans one for input-folder approvals. ADR-18 removes the need for every such split. The user chose to apply it now, while uniterm is pre-v1 and
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

### One store holds every approval

Original question: how should controller approvals be split across files once each file keeps the entries it cannot
read? Today `policy.json` holds package approvals and `files.json` holds script-file approvals. UTERM-032, accepted and
not built, plans a third file for script approvals that hold an input folder.

Decision: every remembered approval lives in `policy.json`: package, driver, script-file, and input-folder approvals.
Each entry names its artifact kind, and a selector matches only runs of its own kind. `files.json` is retired, and
UTERM-032's third store is never built. Amended 2026-11-26; see Decision Log.

**Decided by:** user, 2026-11-26

Rationale: each extra store existed only to keep entries away from older builds that could not read them. ADR-18's
reader does that per entry, and uniterm is pre-v1, so older builds do not constrain the format. One store has one
lock, one cap, one set of kept-aside copies, one way to tell kinds apart, and no rules that span stores.

Turned down:

- Two files with no third store. It keeps two ways to tell kinds apart: by file for package versus script, and by
  field for controller versus driver.
- Three files, as UTERM-032 plans. It keeps UTERM-032's union of duplicates, revoke across two stores, and move order,
  which nothing needs once every reader keeps what it cannot read.
- Merging `files.json` only. It keeps those rules, spanning `policy.json` and the folder store.

### Two entries that name one selector

Original question: between two builds that both have this reader, a newer build writes an approval for a selector at
an edition the older build does not know. The older build keeps it unread, the user trusts the same controller again
there, and the older build writes a second entry for that selector. Today a repeated selector refuses the whole file.
What does the reader do with two entries that name one selector?

Decision: duplicates are allowed. Each entry is read and kept on its own, and a run is covered only by one stored
approval. Trust replaces every entry for the selector that this build can read with one entry that merges them. Revoke
removes every entry for the selector that this build can read. An entry it cannot read stays, and is counted.

**Decided by:** proposal-reviewer (autonomous), 2026-11-26

Rationale: it is the plain behavior. Lookup already checks each matching entry on its own, and Trust and Revoke already
act on every entry with the selector, so only the refusal of a repeated selector goes. Refusing would lose the whole
store, against ADR-18 P1. A union across entries would add a second unit of grant beside the entry, which "One approval
is one entry" keeps single. Removing an unread entry by its selector would read part of an entry ADR-18 P4 keeps whole,
and destroy the newer build's approval. Turned down: the union of readable entries, refusing the file, removing
unread entries by selector, and keeping unknown scopes inside a readable entry, which reopens ADR-18 P4. A revoke in
the older build still leaves the newer build's entry granting there, which the revoke risk accepts.

### Old trust files are set aside

Original question: what does a build with this change do with trust files written in the format before it? Today's
`policy.json` is format 1, and `files.json` holds script-file approvals. UTERM-063, accepted and not built, reuses each
scope's stored number as its permission edition, starting at 0 after its reset. A format 1 file can hold pre-reset
scopes at version 1, which a later edition 1 of the same kind must never read as its own.

Decision: the store's format number moves. A build with this change reads only the new format. It sets every older
`policy.json` and every `files.json` aside with a notice, and the user approves each controller and script again once.
A file at a newer format stays where it is, untouched, and grants nothing. Whichever of UTERM-063 M1 and this proposal
lands second moves the format number again, so a file that holds pre-reset scopes always carries an older format and
is set aside, never read in place.

**Decided by:** user, 2026-11-26

Rationale: the format number at the top of the file is the one indicator every build reads first. Setting old files
aside applies UTERM-063's own rule for a pre-reset file, and no old number is ever read as an edition, which keeps
ADR-14 P10. uniterm is pre-v1, so approving again once is an accepted break, and the old files stay aside for recovery
by hand. A build from before this change reads a new file as newer, or moves aside one it cannot parse whole, as
"Version skew" states.

Turned down:

- Moving old entries into the new file once. It needs a rule that tells pre-reset scopes from post-reset editions, a
  translation step on the trust boundary that serves only builds from before this change.
- Moving them whenever an old file is present. It adds a migration path that never retires.
- Keeping the format number and reading old entries in place. A pre-reset scope at version 1 would wake up as edition
  1 of its kind and grant a meaning the user never approved.

### Every entry this build cannot read is kept alike

Original question: what does the reader do with an entry of a kind it knows whose contents fail its checks, such as a
selector digest that is not 64 hex digits, or a scope missing a required field?

Decision: an entry is either one this build reads in full, or one it cannot read. The reader draws no line between an
entry a newer build wrote and one that is damaged. Every entry it cannot read, for any reason, is kept byte for byte,
grants nothing, and is counted. A key repeated inside one entry makes that entry one this build cannot read. Damage
that stops the reader telling where entries begin and end, such as invalid JSON or a key repeated at the top of the
file, sets the whole file aside. There is no action that removes kept entries. Amended 2026-11-26; see Decision Log.

**Decided by:** user, 2026-11-26

Rationale: a build cannot tell damage from newer rules. A later build may allow a longer name or a new digest length,
which looks as broken to this build as a corrupt value. Today's reader already reports a newer build's unknown
selector kind as unreadable, not newer. The reader is lenient between entries, per ADR-18 P1, and strict within one,
per ADR-18 P4, since acting on an entry with an unknown part dropped could grant a wider meaning than its writer gave.

Turned down:

- A separate damaged count with a Remove action. Its label can be wrong, so Remove can delete a newer build's valid
  approval.
- An action that removes every kept entry. It is an addition, and it deletes newer builds' approvals.
- Setting the whole file aside for a damaged entry of a known kind, against ADR-18 P1.
- Dropping a damaged entry on the next save, against ADR-18 P2.

Leaves undone: a truly corrupt entry stays until someone edits the file by hand. It grants nothing.

### A new version offers to replace the old ones

Original question: how does the store stay bounded without the user cleaning up? Today it holds at most 256
approvals and 1 MiB, and past either a new approval cannot be remembered until the user revokes others by hand. Each
"Trust this version" adds an entry, and nothing removes the old ones, so a script edited often fills the cap alone.

Decision: the store has no count. Its only bound is 4 MiB, fixed with the format number, so a later change to it is a
format change. A file over the bound stays where it is, untouched, and grants nothing, as a newer-format file does. A
write that would pass the bound is refused with a message that says the file looks damaged and names it, never one
that asks the user to revoke approvals.

Each version approval stores what it is a version of: a package's ID, a script's declared ID, or else the script's
absolute path. When the user trusts a new version, the prompt offers to replace the older version approvals of the
same thing, which is the default, or to keep both. Replacing goes through the revoke path, so a live run of a replaced
version ends. What a version approval is a version of only finds older versions to offer. It never decides whether an
approval covers a run.

**Decided by:** user, 2026-11-26

Rationale: the user holds that a bound is wise, that 256 is too low, and that no limit may leave the user cleaning up
approvals by hand. Superseded versions are the source of growth, so replacing them keeps a real store at hundreds of
entries. Keeping both serves two installed versions used in turn. 4 MiB holds about 12,900 typical entries, about 40
times a real set, and reads in about 125 ms. The bound then signals damage, not use. Tying it to the format keeps a
build with a smaller bound from moving a larger file aside. An unsigned script's version approval names only its
digest today, so without the stored path the offer could not find its older versions.

Turned down:

- Replacing with no prompt. Two versions used in turn would keep asking, and a package that claims another's ID could
  remove that one's approvals unseen.
- Raising the bound only. An entry per version piles up for good, lookups slow, and a heavy user reaches the bound.
- Retiring approvals unused for a set time. Every covered run would rewrite the file under the lock, trust the user
  never revoked would go, and it needs a retirement window.
- A higher count with the refusal kept. Growth never stops, so the cleanup by hand returns.

Leaves undone: a script that moves or is renamed starts afresh, and its old entry lingers. A damaged file over the
bound stays unwritable until edited by hand, as "Every entry this build cannot read is kept alike" accepts.

### Version skew

Decision: the store is shared by every build on the machine, and dev and release builds share one folder. Its
behavior across builds is stated, not made tolerant of builds from before this proposal.

- A build from before this proposal reads a new file as newer when its strict reader can parse the whole file: it
  leaves it in place, grants nothing, and saves nothing. A file it cannot parse whole, such as one over 1 MiB or one
  holding a kept entry with a repeated key, it refuses before it reads the format number, and moves it aside. The new
  build then finds that build's fresh file, sets it aside, and starts empty. uniterm publishes no official builds, and
  the user accepts this loss for anyone who runs an older build. It still reads and writes its own `files.json`.
- A build with this proposal sets aside an older `policy.json` and any `files.json`, including one an older build
  writes again later, each time it finds one. Approvals given in an older build never reach the new store.
- Two builds that both have this proposal's reader keep each other's entries. Each grants only from the entries it
  reads in full, keeps the rest byte for byte, and counts them.
- A build whose format is older than the file's reads it as newer, as above. A later change to the bound or to what
  an existing kind means is a format change.

**Decided by:** proposal-reviewer (autonomous), 2026-11-26

Rationale: uniterm is pre-v1, publishes no official builds, and the user accepts breaking changes until then. Every
failure across builds is a file left in place or kept aside, never a silent grant. The one loss is a build from before
this proposal meeting a store it cannot parse whole, which the user accepts. From v1, ADR-18 governs.

### The window shows a count of kept entries

Decision: when a store holds entries this build cannot read, the Controllers & Permissions window shows one line under
the approvals list. It gives the count, says this build cannot read those approvals and they do not apply here, and
says a newer uniterm may read them. It never says a newer version wrote them. Amended 2026-11-26; see Decision Log.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: ADR-18 P5 asks only that the user can see kept entries exist. A row per entry would show parts of an entry
this build cannot read, such as its artifact kind, which ADR-18 P4 keeps whole and unread.

## Design Decisions (Open)

None.

## Risks

- **A revoke in one build leaves an approval another build still grants** — likelihood: medium, impact: medium. A
  build cannot remove an entry it cannot read. When the user revokes a controller there, an entry for the same
  controller that a newer build wrote stays, and the newer build still grants it. Permission editions make this routine.
  Accepted: the user revokes it in a build that reads it, and the window says kept entries exist. See "Two entries that
  name one selector". Rated up from low and low on 2026-11-26; see Decision Log.
- **A corrupt entry stays for good** — likelihood: low, impact: low. No build reads it, so none removes it. Accepted: it
  grants nothing, and the window counts it. The store has no count, so it takes no room the user needs.
- **A moved script leaves its old approval behind** — likelihood: medium, impact: low. A script's version approval
  without a declared ID is a version of its absolute path, so a moved or renamed script starts afresh. Accepted: the
  old entry grants nothing new, the store has no count, and the user may revoke it at leisure.
- **Every approval is given again once** — likelihood: high, impact: low. Old trust files are set aside, and the user
  approves each controller and script again. It happens twice, in either order, unless UTERM-063 M1 and this proposal
  ship in one build. Accepted:
  uniterm is pre-v1, the notice says so, and the old files stay aside for recovery by hand.
- **A build from before this proposal moves a store aside** — likelihood: low, impact: medium. It refuses a file
  it cannot parse whole, such as one over 1 MiB or one holding a kept entry with a repeated key, before reading the
  format. It moves the file aside,
  and the new build then starts empty. Accepted by the
  user: uniterm publishes no official builds, and a user who runs an older build may lose approvals here.
- **Accepted proposals are built before they are amended** — likelihood: medium, impact: low. UTERM-032 and UTERM-063
  are queued, and this proposal is not. UTERM-032 may build its third store, and UTERM-063 its version-based reset
  check, before the amendments in Impacts land. Mitigation: a third store this build finds is set aside like
  `files.json`, per "Old trust files are set aside", and the format tie to UTERM-063 holds in either order. The
  amendments land in those proposals when this one is accepted.
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
- Each store that falls short and is not a trust store has a proposal filed, or is recorded as meeting C1

### M2: The trust stores keep what they cannot read

**Status:** NOT STARTED

- An approval with an unknown permission kind, an unknown selector kind, an unknown artifact kind, or an unknown edition
  grants nothing, and every other approval in the file still applies
- An approval with one unreadable scope grants none of its scopes
- A save from this build writes every kept entry back byte for byte, and a newer build reads it again
- No file is moved aside or left unwritable because of one entry this build cannot read
- A file this build cannot read as a whole, such as one that is not JSON, still grants nothing and is kept aside
- The Controllers & Permissions window shows the count of kept entries
- A `policy.json` at an older format and any `files.json` are set aside with a notice that says each controller and
  script is approved again once. The new file starts empty
- Setting `files.json`, `files.lock`, and the existing `files.aside-*` copies aside does not count toward, or prune,
  the kept-aside copies of `policy.json`
- A file at a newer format grants nothing and stays where it is, untouched
- An entry of a known kind with a value that fails this build's checks is kept and counted like an entry of an unknown
  kind, and every other entry still applies
- A key repeated inside one entry, at any depth within it, makes only that entry one this build cannot read. It is
  written back byte for byte, and the reader still finds where the next entry starts. A key repeated at the top of the
  file, or invalid JSON, sets the whole file aside
- Nesting past the reader's depth bound, an escaped NUL, and an unpaired surrogate inside one entry each have one
  pinned behavior, with a fixture. Each costs only that entry, unless the As built block records why it covers the
  whole file
- The new format number is above every number an earlier build wrote, UTERM-066's included, so no earlier build with
  a strict reader moves the new file aside for an unknown member
- Setting an old `policy.json` or a `files.json` aside never prunes an earlier copy of an old file set aside, and
  writes an empty new-format file at once, so two builds never keep setting aside each other's files
- A UTERM-032 input-folder store, when one exists, is set aside like `files.json`
- The notice that every approval is given again once is shown once, not each time an older build's `files.json` is
  set aside
- Trust folding several readable entries for one unsigned script's digest keeps one defined path
- The replace prompt names the approvals it replaces, and says a live run of a replaced version ends
- The window's line never says a newer version wrote the kept entries
- Remembering never stops at a count. A store of thousands of approvals is read and saved, and the size check on a
  write counts kept entries too, so no save writes a file its own reader refuses
- A file over the bound grants nothing and stays where it is. A write past the bound names the file and says it looks
  damaged
- Trusting a new version of a package, a declared script, or an unsigned script at the same path offers to replace its
  older version approvals or keep both. Replacing ends a live run of a replaced version, as Revoke does
- What a version approval is a version of never takes part in whether an approval covers a run
- Reading a store near the bound takes well under a second, with no per-entry setup such as a new date formatter
- A script-file, driver, or input-folder approval covers only runs of its own artifact kind, and one selector of two
  kinds is two distinct entries
- Two instances of different builds saving the same file keep each other's entries
- A kept entry's exact bytes survive a save, though the strict JSON reader keeps a parse tree and no byte spans
- A file at a newer whole-file format stays where it is, untouched, and is never set aside
- A member at the top of the file that this build does not know does not make the file broken
- Two entries for one selector are both kept. Trust folds every readable entry for the selector into one, so no
  readable scope is dropped, and Revoke removes every readable entry for it
- The window shows two entries for one selector so that what Revoke removes is clear, and selection does not lose
  either row
- The file's sort order breaks ties between entries that share a selector, so one set of entries has one spelling
- An entry this build cannot read is never offered as the nearest match for a run, even when its selector parses

## Decision Log

- 2026-11-26: Filed from UTERM-066's review. The user chose ADR-18's rule, a new ADR for it, and this proposal to
  apply it to the trust stores and check every other store. The user noted that uniterm's formats may break freely
  before v1, and that ADR-18 binds from v1.
- 2026-11-26: Settled both open questions, on the user's instruction to keep going. `files.json` folds into
  `policy.json`, moved once at first launch. The window shows a count of kept entries. Turned down: keeping two files,
  and a row per kept entry, which would read parts of an entry ADR-18 P4 keeps whole. (autonomous)
- 2026-11-26: Review start: 2 milestones, 5 settled decisions, 3 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the whole proposal, at commit "UTERM-067: fold
  files.json into policy.json and count kept entries".
- 2026-11-26: Critique full pass, UNSOUND on six design-level findings: duplicate selectors after an older build asks
  again, a pre-reset policy file against UTERM-063, the fold's missing artifact-kind rule, accepted proposals that
  build on `files.json` and a third store, no skew decision, and deleting `files.json`. The fold's rationale was false:
  a build before this change that meets a script entry in `policy.json` moves the whole file aside, not only its script
  approvals. Reopened the fold.
- 2026-11-26: Replaced "`files.json` folds into `policy.json`" with "One store holds every approval", the user's
  choice. Every approval, UTERM-032's input-folder ones included, lives in `policy.json`, and UTERM-032's third store
  is never built. It said before: "script-file approvals become entries in `policy.json`, each naming its own artifact
  kind, as UTERM-066's driver approvals do. The first launch of a build with this change moves every entry from
  `files.json` into `policy.json` once, then removes `files.json`." The user noted that breaking changes are fine
  before v1, so neither migration cost nor older builds weigh on the choice. Turned down: two files with no third,
  three files, and merging `files.json` only. (addition)
- 2026-11-26: Added Impacts on UTERM-021, UTERM-024, UTERM-026, UTERM-032, and UTERM-063's policy file at the reset.
  Routed checks to M2: exact selector and scopes for any entry carried over, artifact kind in each entry's identity,
  kept bytes surviving a save, a newer-format file left in place, and an unknown top-level member. Narrowed M1's last
  check to match "Every store is checked": it also allowed "an idea recorded". Replaced M2's `files.json` move check,
  which waits on the open question about old trust files. Updated Motivation to name UTERM-032's planned file.
- 2026-11-26: Rated the revoke risk up to medium likelihood and medium impact, and renamed it. It said before: "A
  kept entry the user wants gone survives — likelihood: low, impact: low." A revoke in an older build leaves an entry
  for the same controller that a newer build still grants, and permission editions make that routine.
- 2026-11-26: Opened four questions from the critique and the user: old trust files, two entries for one selector,
  broken entries of a known kind, and the store's bound. The user called the 256-approval cap busy work forced by an
  internal limit, since remembering stops until the user revokes approvals by hand.
- 2026-11-26: Settled "Two entries that name one selector": duplicates are allowed and kept on their own, and Trust and
  Revoke act on every readable entry for the selector. Converged in 1 pass. Turned down: a union of readable entries,
  refusing the file, removing unread entries by selector, and unknown scopes kept inside a readable entry. Routed four
  checks to M2. (autonomous)
- 2026-11-26: Settled "Old trust files are set aside", the user's choice. The format number moves, old files are set
  aside, and whichever of UTERM-063 M1 and this proposal lands second moves it again. Converged in 1 pass, with the tie
  to UTERM-063 added by the critic. Turned down: moving old entries once, moving them whenever present, and keeping
  the format. Routed the notice, the `files.*` aside names, and the newer-format rule to M2, and added the re-approval
  risk.
- 2026-11-26: Settled "Every entry this build cannot read is kept alike", the user's choice. A damaged entry of a
  known kind is kept like an unknown one, and kept entries have no removal action. Converged in 1 pass. Turned down: a
  damaged count with Remove, a remove-all action, setting the file aside, and dropping the entry. Added the corrupt
  entry risk.
- 2026-11-26: Amended "The window shows a count of kept entries" to drop the claim that a newer version wrote the
  entries, which is false for a damaged one. It said before: "N approvals from a newer version of uniterm are kept,
  and do not apply here."
- 2026-11-26: Settled "A new version offers to replace the old ones", the user's choice. The store has no count, and
  its 4 MiB bound is fixed with the format. A file over it stays in place. A new version's prompt offers to replace
  older version approvals of the same package or script, or keep both, and each version approval stores what it is a
  version of, an unsigned script's absolute path included. The critic added the stored path, the over-bound rule, the
  damaged-file message, and replacing through Revoke. Converged in 1 pass. Turned down: replacing with no prompt,
  raising the bound only, retiring unused approvals, and a higher count. Routed six checks to M2, and added the moved
  script risk. (addition)
- 2026-11-26: Added "Version skew", which states the behavior across builds: a build from before this proposal reads
  the new file as newer, a `files.json` an older build writes again is set aside each time, and builds with this
  reader keep each other's entries. Narrowed the UTERM-066 Impacts line, which said driver entries stop cutting off an
  older build without naming which builds. (autonomous)
- 2026-11-26: Re-check pass, NOT CONVERGED on two design-level defects. A build from before this proposal refuses a
  file over 1 MiB before it reads the format number and moves it aside, which "Version skew" said never happens. The
  user accepted the loss: uniterm publishes no official builds, and anyone running an older build may lose approvals
  here. "Version skew" and "Old trust files are set aside" now state it, and a risk records it. A key repeated inside
  one entry set the whole file aside, against ADR-18 P1. By the user's choice it now makes only that entry unreadable.
  "Every entry this build cannot read is kept alike" said before: "Damage that stops the reader telling where entries
  begin and end, such as invalid JSON or a key repeated anywhere in the file, sets the whole file aside." Routed six
  checks to M2, and fixed four wording slips in Impacts and Risks.
- 2026-11-26: Risk review added "Accepted proposals are built before they are amended", since UTERM-032 and UTERM-063
  are queued and this proposal is not. Mitigated by setting aside a third store like `files.json`, routed to M2, and by
  the format tie, which holds in either order. Every other risk carries a rating and a mitigation or acceptance. None is
  rated high likelihood and high impact. (autonomous)
- 2026-11-26: Last re-check pass, NOT CONVERGED on one wording defect. A build from before this proposal also moves a
  file aside when a kept entry holds a repeated key, since its strict reader refuses one at any depth. "Version skew",
  the rationale of "Old trust files are set aside", and the older-build risk named only the over-1 MiB path. Widened
  all three to "a file it cannot parse whole". The loss falls under what the user accepted, so no decision changed.
  Routed a nested repeated-key fixture check to M2.
- 2026-11-26: Closing re-check, NOT CONVERGED on one stale line. The UTERM-066 Impacts line still said a build from
  before this proposal always reads the new file as newer. Corrected it to match "Version skew", and changed the cause
  lists there and in the risk to examples. No decision changed. Routed a check on the strict reader's other refusals
  inside one entry to M2.
- 2026-11-26: Review gate: kept all. The user settled every decision that changed the design during the review. The
  two decisions taken without asking, "Two entries that name one selector" and "Version skew", carried no dissent and
  no addition. No decision earns an ADR: each new rule applies ADR-18 P1 to P5 or ADR-14 P8 and P10. The proposal stays
  `designing` until the user accepts ADR-18, per Dependencies.

## References

- ADR-06: the layout file's payloads already keep what an older build cannot read
- ADR-14: remembered approvals and their scope
- ADR-18: stored data a build cannot read is kept, and never acted on (proposed)
