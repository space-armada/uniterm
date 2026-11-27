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

Committed as "Check every store against ADR-18 and draft fixes for the ones that fall short".

## UTERM-067 M2

### What was built

- `policy.json` is format 3 and holds every approval. Each entry names its artifact kind. A version approval may name
  what it is a version of. `files.json` is no longer a store.
- A scanner finds each entry's exact bytes. The strict reader then parses one entry on its own. A fault inside an entry
  costs only that entry: a repeated key at any depth, nesting past the bound, an escaped NUL, an unpaired surrogate, an
  unknown kind, or an edition above this build's. Invalid JSON, a repeated top-level key, a byte order mark, or bytes
  that are not UTF-8 set the whole file aside.
- An entry this build cannot read grants nothing, is never the nearest match, and is written back byte for byte.
  Unknown top-level members are written back too.
- The store has no count. Its only bound is 4 MiB. A file over it stays untouched and grants nothing. A write past it
  names the file and says it looks damaged.
- An older `policy.json` and any `files.json`, with its lock and aside copies, move into a `retired/` folder. Nothing
  there is pruned. An empty format 3 file is written at once, and the re-approval notice shows once.
- Trust folds every readable entry for a selector into one. Revoke removes every readable entry for it.
- The Controllers & Permissions window shows one line with the count of approvals this build cannot read. Two entries
  for one selector both show.
- Trusting a new version offers to replace its older version approvals, on by default, or keep both. The prompt names
  each approval it replaces, and says a live run of a replaced version ends. Replacing goes through the revoke path.
- UTERM-066's four mentions of its planned format 2 now say UTERM-067's format 3.

### Implementer best guesses

- Old files go to a `retired/` folder with a `.notified` marker. The proposal says "set aside" and names no place. If
  wrong, they would be numbered copies beside `policy.json`, with a second prefix to keep them out of its five.
- `versionOf` is optional. A version entry without one reads and covers, since it takes no part in coverage.
- The UTERM-032 store has no name in any proposal, and UTERM-032 no longer builds one. The store retires any earlier
  store it is told of, and `files` is the only one a build ever wrote.
- Unknown top-level members are written back, as ADR-18 P2 asks. The bullet said only that they do not break the file.
- Bytes that are not UTF-8, and a byte order mark, set the whole file aside.
- The replace choice is a checkbox under the review, not a second button. A signed controller's button row has no room.
- "Well under a second" rests on a one-off release measurement of about 110 ms for 8,500 approvals at 3.8 MiB. A debug
  read takes about 1 s. The test proves "no per-entry setup" by counting date parser setups, and keeps the wall clock
  only as a coarse guard.

### Checks

- `make fmt-check lint check`: pass.
- `make fuzz`: 24 tests pass, 297 s, after the review fixes.
- `caffeinate -dimsu make test-package`: the coordinator's run before the fixes passed 3368 tests, 10 skipped, in 288 s.
  The implementer's run after the fixes passed 3372 tests in 283 s. `ProcessReaperTests` passed in every run.
- `xcodebuild build-for-testing`: TEST BUILD SUCCEEDED.
- Test cost of the new classes, in debug: `ControllerKeptEntriesTests` about 1.8 s, `FilePolicyTests` about 4 s,
  `StoredTrustTests` about 0.6 s.

### Review

- adr-impact: no conflict. The store meets ADR-18 P1 to P5, and ADR-14 holds, since a replace is a prompted revoke. The
  store is read off the main thread, per ADR-08. It named the retiring of old trust files as a decision with no ADR. The
  user settled that in "Old trust files are set aside", and the proposal's log says no decision earns an ADR. Not
  recorded as a candidate.
- The reviewer attacked the reader as the trust boundary. It found no path where an entry with an unreadable part
  grants. A scanner and strict reader that disagree can only turn an entry into a kept one. It had nine findings, all
  fixed:
  - CONFIRMED: Trust This Version removed approvals the prompt never named. With two versions waiting for review,
    trusting the second removed the first's approval and ended its runs. A replace now removes only what the review
    named. The regression test failed on the old behaviour first.
  - PLAUSIBLE: the timed read test allowed 3 s, so it could not catch a per-entry formatter. A count of parser setups
    now proves the bullet.
  - PLAUSIBLE: a script path with a newline, a tab, or over 4096 bytes produced an entry the store's own reader kept
    unread. The trace confirmed the path can reach it. The writer and reader now share one rule, and such a path is
    saved with no `versionOf`.
  - A test name's typo, a missing table test for strings that look like structure, a doc that contradicted its test,
    two docs that still said "set aside", a fourth stale format line in UTERM-066, and the UTERM-032 store's naming.

### UI checks

- The coordinator ran `ControllerConsentUITests`, `PendingRequestsUITests`, and `ControllerRunUITests` at 14:28: 14
  tests, 3 failures. The two new tests passed.
- The three failures were `ControllerConsentUITests.testASignedFilesReviewOffersTrustThisIdentity` ("Timed out while
  synthesizing event") and both `PendingRequestsUITests` tests (a menu click with no point, and "the Pending Requests
  panel never opened").
- Cause: another app came to the front during each one. The run's log has `[frontmost] Activation` lines for Google
  Chrome at 14:29:50 and WezTerm at 14:31:32, right at the failures. The machine was in use. All three passed when run
  again at 14:32.
- The same holds for the four failures in the UTERM-063 M2 run at 13:05, which that row's report left unresolved. Its
  log has activations of WezTerm, Mattermost, and Google Chrome beside each failure.
- The coordinator viewed both screenshots from the 14:28 run:
  - `controllers-and-permissions-unreadable`: one readable row, and under the list "This uniterm cannot read 1
    approval in its policy file, so it does not apply here. A newer uniterm may read it. The file keeps it as written."
  - `pending-requests-replace-older`: the review says "Trust This Version replaces 1 older approval of
    dev.uniterm.uitest.consent", names it with its version and date, and says a live run of a replaced version ends. The
    box "Replace the older versions listed above" is checked, above the four buttons.

Committed as "Keep every approval the trust store cannot read, in one policy file".

## Rebase

At the user's request the branch was rebased onto `upstream/main`, at "Merge pull request #125", once M2 was
committed. The rebase applied with no conflict, and one redundant snip was dropped. `make fmt-check lint check test-ci`
passed on the rebased tree, and the full package suite passed 3372 tests.

## Row review

- adr-impact: no conflict. ADR-18 is still proposed. Its notes, all taken up below: M1's table was stale after M2, the
  five-copy limit M1 assigned to M2 was kept with no record, and bytes that are not UTF-8 inside one entry cost the
  whole file. It also noted that ADR-18's line "The trust stores do not meet P1 today" is now stale. The run does not
  edit that ADR. It is left for the user.
- The reviewer had five findings, all fixed:
  - CONFIRMED: the scanner set the whole file aside for a control byte, an unknown escape, or a short `\u` escape inside
    one entry's string. None hides where the string ends. The scanner now judges boundaries only, and each fault costs
    its entry. The regression test failed first.
  - M1's table said M2 fixes the aside copies' limit, and M2 kept it. M2's As built now records that the limit of five
    stays, as an open ADR-18 P2 question shared with the layout file. UTERM-071's open question covers both. M1's table
    gained an "After M2" note.
  - The M2 check on a UTERM-032 store was narrowed only in the log. Amended in place, with two other checks.
  - UTERM-066 still said UTERM-067 was not built. Amended.
  - PLAUSIBLE: two hand-written tokenizers could drift. A seeded differential test now holds the scanner's ranges to
    what the strict reader parses. They stay separate, since a tolerant mode would loosen the strict reader.

### Best guesses

- Bytes that are not UTF-8 inside one entry now cost only that entry. Such a byte is 0x80 or above, so it can never be
  a quote, brace, bracket, or comma. Outside every entry they still set the file aside, as does a byte order mark.
- The limit of five whole-file aside copies stays. M2's own checks presuppose the copies continue. If wrong, the store
  needs a retention rule that meets ADR-18 P2, which UTERM-071 will decide for both stores.

### Checks

- `make fmt-check lint check`: pass. `make fuzz`: 25 tests pass, 351 s.
- The implementer's full run failed `ProcessReaperTests.testTheReaperLogsThePidPathAndFailuresButNotAGoneHelper` again.
  Filed as `spec/bugs/20261127-reaper-log-test-reads-no-entries-in-some-full-runs.md`, not confirmed.
- The coordinator's full run at 14:56 passed the reaper test and failed
  `ScriptLimitsTests.testASecondCtrlCEndsAScriptStuckInACallTheInterruptNeverReaches`, 3374 of 3375 passing. That is the
  open bug `20261114-second-ctrl-c-test-flaky-under-full-suite`, which now carries this third sighting. The class
  passed alone right after, with `ControllerTrustTests`. Neither failure touches this row's code.
