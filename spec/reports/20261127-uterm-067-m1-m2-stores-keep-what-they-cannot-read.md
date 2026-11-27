# UTERM-067 M1-M2: stores keep what they cannot read

Started 2026-11-27, as the sixth row of the day's second `/work-queue` run of `next 6`. The run's state is in
[the UTERM-044 M3 re-check report](20261127-uterm-044-m3-failed-shard-reruns-alone-recheck.md). Every commit is in this
repo, on `agent/petunia`.

The row has no dependencies and no `Live after` line. Its base is "Mark UTERM-063 implemented and move its finished row
to history". The M1 audit started while the UTERM-063 row review ran, since it wrote only spec files that row did not
touch. Its commit came after the UTERM-063 row finished.

## Best guesses from the plan

- The trust stores' format moves 2 → 3 in M2. It must exceed UTERM-063 M1's 2 and UTERM-066's planned 2.
- An unknown, higher edition makes only that entry unreadable from M2 on. An older edition reads but does not cover.
- M1 files the stores that fall short as `draft` proposals, unscheduled.

## UTERM-067 M1

### What was found

The audit listed every store a build writes and reads back, from the code. The reviewer searched again and found none
missed.

| Store | Result | Proposal |
|-------|--------|----------|
| Trust stores `policy.json`, `files.json` | Fall short of P1 and P2 | M2 of this proposal |
| `layout.json` and its kept-aside copies | Fall short of P1 except where C1 applies. Unread members dropped on save, against P2, P4, and P5. Only five aside copies kept | UTERM-071 |
| Applet payloads inside the layout | Meet P1 to P5 | none |
| `Browser/hsts.json` | Falls short of P1, P2, P4, P5 | UTERM-072 |
| Open With choices | P5 gap: a non-string entry cannot be seen or cleared | UTERM-073 |
| Settings in UserDefaults | Meet | none |
| Scrollback files | Read once by design. A kept-aside layout outlives its scrollback file | routed to UTERM-071 |
| Signing keys in the Keychain | Meet | none |

Not stores: per-instance terminal config, sent content, the socket folder, controller-run caches, WebKit data, the
map's command-pin snapshot, which stays in memory, and documents the user saves.

ADR-18's guarantee starts at version 1, so none of these stores breaks it today. The drafts bring them in line before
then, as "Every store is checked" asks.

### Drafts filed

- UTERM-071, "The layout file keeps the windows and nodes it cannot read". Its open candidates that would amend
  ADR-06, or deviate from ADR-18 P2 or P4, are labelled as needing the user's decision.
- UTERM-072, "The HSTS store keeps the entries it cannot read".
- UTERM-073, "Open With shows the choices it cannot read".

None is scheduled.

### Best guesses

- One draft per store, since each store has its own reader.
- Settings in UserDefaults meet ADR-18: an invalid value falls back in memory, and the stored value is left alone.
- Scrollback meets ADR-18 as a store, since each file is read once by design. A kept-aside layout that names a swept
  scrollback file is a question for UTERM-071's kept-aside copies.

### Checks

- `proposals.py check`: only the three pending-override findings on UTERM-019 and UTERM-050.
- `proposals.py freeze`: no hunk on UTERM-067 or the drafts. The four origin `other` hunks remain.
- No code changed, so no build or test ran.

### Review

- adr-impact, and the reviewer, raised these, all fixed:
  - The layout row said a newer schema version meets C1, since the version signals a change of meaning. ADR-06 bumps
    the version for additions too, so C1 covers only the panes inside a new node. The row now says the layout falls
    short of P1 except where C1 applies, and UTERM-071 holds the question.
  - UTERM-071 listed candidates that would amend ADR-06, or that ADR-18 P4 rejects, without saying so. Labelled.
  - Open With had a P5 gap and no proposal. Filed UTERM-073.
  - The scrollback row recorded a loss and still said "Meets". It now gives the reason, and routes the loss to UTERM-071.
  - The audit did not say ADR-18 binds only from version 1. It does now.
  - The Decision Log entry was tagged "(autonomous)". Split into four entries tagged "(run best guess)".
  - The As built table named code symbols. Dropped, keeping the store paths.
- The reviewer confirmed the audit's code claims, and that the UTERM-067 diff held only this milestone's work.
- adr-impact named three decisions the drafts will face with no ADR: what unit a store keeps unread, whether a user's
  clear removes unread entries, and how long a kept-aside file lives. Each is open in a draft, and none is settled, so
  none is recorded as an ADR candidate yet.
