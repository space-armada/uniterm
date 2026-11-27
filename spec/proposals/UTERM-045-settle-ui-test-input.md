# UTERM-045: Settle Input Before UI Tests Send It

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-24

## Impacts

- UTERM-044 — Risks: "Splitting moves a flake rather than fixing it" names this proposal as part of the fix.
- UTERM-046 — its entries stay under Potential until CI shows its fixes hold. The closing rule M1 writes into the
  `spec/flaky-tests.md` Rule section decides when they may move to Fixed.

## Summary

UI tests send synthesized wheels, clicks, and keys. When an event arrives before its target can take it, the test
fails with no change to the code. This proposal gives the UI test base class one way to aim and send a wheel that
settles the pointer first, once CI shows the launcher change holds. Every XCUI wheel in the UI tests moves onto it. It
also states when a flaky entry may close.

## Motivation

One logged flake has evidence of a pointer race. In a CI failure of the launcher scroll test on #90, the first wheel
scrolled the middle pane's launcher while the same lookup gave the focused list's frame just before and after it. The
change "Settle the pointer on the launcher list before the scroll test's wheels" moves the pointer onto the list and
waits until it is inside before any wheel. That change is a hypothesis. A local run that left the pointer over the
middle pane still passed, and CI had run it once by the time this proposal was filed.

The other wheel sites, such as the image viewer's scroll test (`UITests/ImageViewerUITests.swift:507-538`), send raw
`element.scroll` calls with no settle. If the race is real, they share it.

Most other entries in `spec/flaky-tests.md` point elsewhere. The open-panel failures involve a panel in another
process. Several entries record a single synthesized event taking 5 to 20 s. `TerminalLinkUITests` failed because a
person moved the real mouse during a local run. The PaneTree entry's own check rules out a responder race in the app.

## Design Decisions (Settled)

### Test code only

Decision: no product code changes. The change lives in the UI test target, a check script, the Makefile, and
`spec/flaky-tests.md`.

Rationale: the events are synthesized by the test, and the race is between the test and the window server.

### No retries and no longer timeouts

Decision: a settle waits for a stated precondition, such as the pointer inside the target's frame, and fails with a
report when it never holds. It never resends an event or widens a timeout. It never waits on the outcome of the event it
comes before.

Rationale: the flaky-test rule forbids fixing a flake with retries, longer timeouts, or weaker assertions. A wait for
the test's own precondition removes the race, and its failure names which precondition did not hold.

### When an entry closes

Decision: an entry moves to Fixed only with a fix commit, and only after enough clean CI runs that a flake still
present at its observed rate would very likely have shown. For an entry seen once in N runs, that is about 3N clean
runs, which gives a 95% chance of seeing it again. An entry seen too rarely to reach that stays under Potential, with
the change named. A run that fails with a settle's report closes nothing. It records a new cause on the same entry.

Rationale: the launcher entry moved to Fixed after one change on 2026-11-21, and CI then failed it again. Three clean
runs say little about a flake seen once in twenty.

### Which call sites move

Original question and candidates:

- **Every synthesized wheel.** Every wheel goes through one base-class entry point that aims and settles, so a new
  wheel test gets the settle by default. Takes in the image viewer's wheels, which have no flaky entry. An addition.
  Leaves undone: keys, and the `QuestionsUITests` Escape retry.
- **Wheels and keys.** As above, plus a keyboard-focus settle before keys. Today a test waits once for the app to be
  frontmost, in `waitForTerminal` (`UnitermUITestCase.swift:131`), not before each key. A focus settle would wait for
  the app's first responder, which is the app's response to the last action, against the decision above. It also
  cannot see the open panel, which runs in another process. `QuestionsUITests` resends Escape up to three times for a
  panel not yet ready, a retry this option would have to replace. An addition.
- **Flaky entries only.** Only tests with a logged pointer flake move, which today is the launcher test. Leaves
  undone: raw wheels elsewhere, and the `QuestionsUITests` Escape retry.

Decision: every synthesized wheel. Every XCUI wheel in `UITests/` goes through the one base-class call that aims and
settles. That is the launcher test's two wheels, the image viewer data table's three, and the image pane's one. The
image viewer's sites have no flaky entry, so this is an addition. A check in `make check` fails when a UI test sends
an XCUI wheel outside the shared call, so a new wheel test gets the settle by default. The check is an addition too.
Package tests that feed events straight into a view, such as `ImageViewerScrollTests`, send no XCUI wheel and are
outside this decision.

Rationale: the data table's first wheel (`UITests/ImageViewerUITests.swift:507`) is a first aim, as the launcher's
was. If it lands elsewhere on a runner whose wheel goes up for a positive delta, the next two wheels push against the
top, and the test fails with "the table did not move". So the race the launcher showed reaches it too. One call fixes
the structure that let the launcher test send a wheel before the pointer arrived. The other candidates leave that
structure in place. Flaky entries only behaves exactly as no change, with a helper of one caller. Wheels and keys adds
a key settle with no element to wait on: a shortcut such as Cmd-D targets the app, and the keys-gone-nowhere entries
point outside the app. Without the check, the raw call stays the obvious path, and it passes locally, where the race
does not show. A bypass would then surface only as a CI flake, the event this proposal exists to prevent. A runtime
swizzle of XCTest's scroll methods was weighed. It patches XCTest's own classes, which an Xcode update can break.

### What a clean run is

Added by the review. UTERM-044 may split CI's one `app` job into shards, so the closing rule's "clean CI runs" needs a
meaning that holds either way. Candidates: test-level, where the entry's test ran and passed whatever else failed;
job-level, where the job or shard that runs the test passed; whole-run level, where the required `ci` check passed.

Decision: test-level. An entry's tests are every test its sightings name. A clean run is a CI run attempt in which the
entry's tests started on a head that holds the fix, and all passed. Other failures in the same job or shard do not
matter. A run attempt in which the test never started, such as a skipped job, or one cancelled by a person or a newer
push before the test, neither counts nor breaks the streak. The same holds when only some of the entry's tests started
and each one that started passed. A failure of one of the entry's tests that is logged under another entry, by its failure
line and message, neither counts nor breaks the streak. A test that started and did not finish, such as one cut off by
a job timeout, a crash, or a newer push, is not clean, and breaks the streak. Each attempt of a rerun is its own run, and runs are ordered by when the
attempt finished. The count comes from the per-test `passed` and `failed` lines in each attempt's step log.

Rationale: the closing rule's arithmetic counts trials of the entry's test. A job-level count also tests the job's
neighbors. Since the launcher change, 3 of 16 `app` jobs failed on other tests, so a run of 60 clean jobs, which an
entry seen once in 20 runs would need, has a chance of about 3 in a million. The bar would also move with UTERM-044's
shard count. The test-level wording names no job, so it reads the same with one `app` job or with shards.

### How the wheel is aimed

Original question and candidates:

- **Hover, wait, then the element's scroll.** What the launcher change does. Whether XCUI's element scroll moves the
  pointer again before the wheel is not known.
- **Scroll at a coordinate.** `XCUICoordinate.scroll(byDeltaX:deltaY:)` sends the wheel at an explicit point, which
  also avoids XCUI's hit-point lookup that fails for the launcher's scroll view. Whether it removes the race is not
  known.

The xcresult activity log for one wheel shows which events XCUI synthesizes, and decides between these.

Decision: hover, wait, then `XCUICoordinate.scroll(byDeltaX:deltaY:)` at the point the hover used. The point lies in
the target's visible part, and the wait checks that the pointer is inside the same rectangle. So the wheel goes to the
point the wait checked, whatever XCUI does inside the call. A local trace in M2 records the pointer moves and wheels
the runner sees, and shows that none moves the pointer between the settle and the wheel.

Rationale: with the element's own scroll, XCUI picks the wheel's point. For the data table, whose frame spans its
document, that point need not be the hover point. XCUI would then move the pointer again just before the wheel, which
is the unsettled move this proposal removes. The launcher's 16 clean CI runs back hover-then-wheel on a fully visible
list, where the two points plausibly coincide. They say nothing about the table. M2 already earns a fresh CI count for
the launcher once it moves onto the shared call, so the coordinate aim restarts nothing extra. Reading the xcresult
activity log was weighed. A step log shows XCUI's records, not the window server's event order, so it may not decide
between the aims.

### Whether clicks need settling

Original question: XCUI's `click()` aims at the element as part of the click. Whether a click can land before the
pointer arrives is not known, and no logged flake shows it. Candidates: settle clicks too, or leave clicks until a
flake shows the race.

Decision: leave clicks as they are. A click goes through no shared settle.

Rationale: about 196 click sites run in every CI run, and no logged entry shows a click landing off its target. The
open StatusBar click entry is a 5 s synthesis stall, and PendingRequests is a hit-point lookup failure. A settle
changes neither. A hover before every click would also add pointer moves that tests do not send today, and
`TerminalLinkUITests` builds its exact move sequence on purpose.

**Revisit:** when a logged click flake has a screenshot or a report that puts the click outside its target. A click
failure's report gives no pointer position today, so a screenshot is the likelier evidence.

### Whether to detect outside input

Original question and candidates:

- **No detection.** Document that a local UI run needs the pointer and keyboard left alone.
- **Check pointer drift.** Before each event, compare the pointer with where the settle put it, and fail when a person
  moved it. An addition. Leaves undone: a person's modifier keys still change synthesized input, which was the
  TerminalLink cause.

Decision: no detection. The `spec/flaky-tests.md` Rule section and the help for `make test-app` and
`make test-app-select` say that a local UI run needs the pointer and keyboard left alone. The help text is an addition.

Rationale: CI runners have no person at the input devices, so the exposure is local only. The cause it would detect is
known and written down. A drift check covers only the six wheels, and the TerminalLink incident behind this question
sent no wheel and was caused by modifier keys. A hardware-input check would fail every test if XCUI's own events reset
its counter, which is not known. Leaves undone: a person's input during a local run still fails a test with a message
that names no cause.

### Which observed rate sets the count

Added by the review. The closing rule says "an entry seen once in N runs" and does not say over which window.
Candidates: the latest burst, as M1 had it, 5 of 10 runs, so 6; the rate since the last fix; the whole history since
the first sighting; the larger count of those two; a fixed floor such as 20 runs over the whole history; the lowest
rate in any window between the fixes the entry records.

Decision: the lowest rate between fixes. The entry's CI history, from its first sighting to the fix under test, splits at
each fix the entry records. A window begins at the first CI attempt whose head holds that fix. A commit that only adds a
report, such as "Report where the launcher list stood after each wheel in the scroll test", does not split it. N comes
from the lowest failure rate among the windows, counting CI attempts that ran any of the entry's tests, and the count is
3N. The attempts counted include those in which only some of the entry's tests started. A window with no failure sets no
N. It observed no failure rate, and the closing rule targets observed rates. A cause that survived into that window fails
less often than any window that failed, and the count does not chase it. A later change that restarts the count asks
about the cause that change might bring, which no earlier window saw. An entry with no CI failure at all has no N and
stays under Potential, as the closing rule says. For the launcher, the windows split at "Wait for the launcher's last
entry to come into view after a scroll" and "Scroll the short launcher either way the machine's wheel goes". By commit
time they hold 2 failures in 22 attempts, 4 in 20, and 3 in 19. The lowest is 2 in 22, so N is 11 and the count is 33.
Amended 2026-11-24; see Decision Log.

Rationale: a cause that survives every fix fails in every window at its own rate, so the lowest window rate bounds it.
The whole history is a weighted average of the windows and never goes below that lowest window. When an earlier fix
removed a frequent cause, the whole history overstates the rate of the cause that is left. Then the count is too
small: a cause failing 1 in 20 passes 14 clean runs about half the time. The larger count of the whole history and the
latest window misses a quiet window in the middle. The lowest window's rate is still a small-sample estimate, and it
can overstate the true rate: a cause failing 1 in 10 shows 3 or more failures in 15 attempts about a fifth of the
time. So the 95% is a target the count aims at, not a guarantee. The latest burst picks the highest rate by
construction. A fixed floor is a number nobody asked for, and it still misses a 1-in-20 cause at 20 runs about a third
of the time.

## Design Decisions (Open)

None.

## Risks

- **The launcher hypothesis is wrong** — likelihood: medium, impact: medium. Mitigation: M2 starts only after M3's
  clean count. Amended 2026-11-25; see Decision Log. A CI failure with the pointer inside the list disproves the cause,
  and the proposal is then retargeted or retracted, before anything is built on it.
- **A settle never actually waits** — likelihood: medium, impact: low. Mitigation: if `hover()` returns only after the
  pointer moved, the wait proves the precondition but guards nothing. The wheel goes to the coordinate the wait
  checked, so the settle at least pins the wheel's point. M2's event trace shows whether any pointer move falls
  between the settle and the wheel, and the call's comment says what it guards. The trace runs locally, where the race
  does not show. It shows which events XCUI posts, not how a CI window server times their delivery. CI's clean count
  is the only proof of the timing.
- **M2 replaces an aim that CI has proven** — likelihood: medium, impact: medium. Mitigation: M2 moves the launcher
  from the element's own scroll, clean in 16 CI runs, to a coordinate scroll with no CI history. M2 earns its own
  clean count. A launcher wheel failure after M2 with the pointer inside the list reopens the aiming question, with
  the element's own scroll as the known-good fallback.
- **The closing rule keeps entries open a long time** — likelihood: medium, impact: low. Accepted: a window with a low
  failure rate sets a high N, so an entry seen rarely may need dozens of clean runs before it closes. An entry left
  under Potential costs a longer list, never a wrong Fixed.
- **The settle reads the wrong coordinate space** — likelihood: low, impact: low. Mitigation: a wrong conversion fails
  the wait every time, never silently. The launcher change's local runs already passed with it.

## Milestones

### M1: The closing rule and the launcher recount

**Status:** DONE

- The `spec/flaky-tests.md` Rule section states the closing rule above, in place of moving an entry to Fixed on a fix
  commit alone
- The Rule section's closing rule defines a clean run as "What a clean run is" does, names no CI job or shard, and
  reads the same with one `app` job or with shards. The launcher recount reads every attempt of every run
- The Rule section takes N, for every entry, from the lowest failure rate among the windows between the fixes the
  entry records, as "Which observed rate sets the count" says. A window with no failure sets no N. The launcher entry
  records each fix the split uses
- The Rule section says a failure of one of the entry's tests that is logged under another entry, such as a launcher
  failure before the wheels, neither counts nor breaks the streak. The failure's line and message decide which entry
  it belongs to, and a wheel failure always belongs to the launcher entry
- The Rule section and the help for `make test-app` and `make test-app-select` say that a local UI run needs the
  pointer and keyboard left alone
- A launcher-test failure before the wheels, such as no launcher after Cmd-Shift-D, is logged in its own entry and
  does not restart the count
- A pass counts only from a job that ran in that attempt. A job a rerun carries from an earlier attempt counts once
- The Rule section says N's denominator counts every CI attempt that ran any of the entry's tests, partial starts
  included, and that a test cancelled mid-run by a newer push did not finish and breaks the streak
- The Rule section takes N from CI attempts only, as it counts clean runs. A sighting from a local run is logged, and
  adds nothing to N
- The Rule section says that a Fixed entry seen again moves back to Potential with the sighting

**As built:**

- The Rule section, the help text, and the recount are done. The count moved to M3. N is 11 and the count is 33. The
  streak since the pointer change is 23 clean runs through 2026-11-25T07:27:48Z, so 10 remain. The figures are in the
  Decision Log.

### M2: One way to send a wheel

**Status:** NOT STARTED

- The base class aims and settles a wheel in one call, and reports the pointer and the target's frame when the
  precondition never holds
- The settle reads the target's frame on each poll
- The call aims at the visible part of the target: its frame clipped to its enclosing scroll view and window. The wait
  checks the same rectangle. A table whose frame spans its whole document, as the image viewer's data table does,
  still gets a pointer inside its visible rows
- The wheel is an `XCUICoordinate.scroll` at the point the hover used, and that point lies inside the rectangle the
  wait checked. A coordinate built from the table's normalized frame would not, since that frame spans the document
- A local trace of the runner's pointer moves and wheels, such as an `NSEvent` global monitor, shows no pointer move
  between the settle and the wheel, and the wheel's location inside the target. The result goes in the As built block
- Every call site the scope question names uses it, and no raw wheel remains among them
- A settle that times out fails with its own message, distinct from the test's own assertion
- `make check` fails when a UI test sends `scroll(byDeltaX:deltaY:)` outside the shared call. It ignores comments,
  matches a call split across lines, and exempts only the one call inside the shared helper. It lands in the change
  that moves the last raw wheel
- The diff touches only the UI test target, the check script, the Makefile, and `spec/flaky-tests.md`
- When M2 lands, the launcher entry moves back to Potential, naming M2's change, since a change to the aim restarts
  the count. It returns to Fixed once M2's count is met. Its N follows "Which observed rate sets the count". When the
  window from the pointer change to M2 holds no failure, it sets no N, and the count is M1's
- The check script has fixtures that show it rejects a raw wheel split across lines, ignores one in a comment, accepts
  the one call inside the shared helper, and rejects a raw wheel elsewhere in that file
- Clean CI runs, as "What a clean run is" defines them, prove the change to the launcher entry's count from M1. Local
  runs do not count

### M3: The launcher count is met

**Status:** DONE

- The launcher change has run clean in consecutive CI runs, as built, to the count the closing rule sets. The rate that
  sets the count follows "Which observed rate sets the count": 2 failures in 22 attempts, so 33 runs. Amended 2026-11-24;
  see Decision Log. A clean run is one as "What a clean run is" defines it. The launcher entry records the count, and
  notes that 5 of the clean runs came before "Poll UI test waits every quarter second instead of XCTest's second". A
  wheel failure, or a change to the aim, restarts the count. M2 does not start before the count is met
- The launcher entry stays under Potential until the count is met, whichever version of `spec/flaky-tests.md` lands
- A CI failure with the pointer inside the list sends the proposal to the user to retarget or retract
- A CI failure in which the settle's own wait timed out, or the pointer left the list after the settle, is recorded in
  the launcher entry, restarts the count, and reopens the aiming question

**As built:**

- The recount ran from 2026-11-25T07:27:48Z through 2026-11-26T05:25:54Z by the Rule's method. The streak reached 33
  consecutive clean CI attempts, which meets the count. No attempt failed the launcher test.
- The launcher entry moved to Fixed in `spec/flaky-tests.md`, naming both changes and the count met.
- The four missing job logs are judged by run time, as the Decision Log entry for 2026-11-27 records.
- The count is M1's, since no window after the pointer change holds a failure.

## Decision Log

- 2026-11-21: Filed during a landing run in which UI flakes cost several CI reruns. The user asked whether this
  flakiness could be fixed for the future.
- 2026-11-21: A design review found the premise rested on one unconfirmed pointer race. The user chose to gate the
  work on CI evidence for the launcher change, widen the scope candidates to every synthesized wheel, and state a
  closing rule.
- 2026-11-22: Review start: 2 milestones, 3 settled decisions, 3 risks, no `**Live after:**` lines, one row gate (M2
  waits on M1's count); out of scope: product code. Reviewed at "Schedule UTERM-018, 040, 039, 033, 048, and 049 at
  the end of the queue". The review settles the four open questions, and words the closing rule's clean run so it
  holds whether CI runs the UI tests in one `app` job or in shards, as UTERM-044 proposes.
- 2026-11-22: Fact: since "Settle the pointer on the launcher list before the scroll test's wheels", 16 CI `app` jobs
  ran the launcher test to completion, and it passed in all 16. Every attempt was read. Two runs had a second attempt.
  In one, the second attempt carried the first attempt's passing `app` job without running it again, and it counts
  once. In the other, the first attempt's `app` job was cancelled before the test. Every head held the change. 5 of
  those runs came before "Poll UI test waits every quarter second instead of XCTest's second", which cut the test from
  about 13 s to about 7 s. 3 of the 16 jobs failed on other tests:
  `TextViewerUITests.testAREADMERendersInTheLightAndDarkThemes`, two `Command-O` tests in one run, and
  `QuestionsUITests.testEveryAnswerTypeReturnsItsShape`. So the longest run of fully clean `app` jobs is 5.
- 2026-11-22: Every synthesized wheel in `UITests/` moves onto the one base-class call, the image viewer's four
  included, since its data table's first wheel is a first aim like the launcher's (autonomous, addition; depends on
  keeping M2). Converged in 1 pass. Routed to M2: the call aims at the target's visible part, since the data table's
  frame spans its document.
- 2026-11-22: A clean run is test-level: the entry's test started on a head holding the fix, and passed, whatever else
  failed. The wording names no job, so it holds with one `app` job or with UTERM-044's shards (autonomous; depends on
  the 95% target). Converged in 1 pass. The re-check passes later found design-level gaps in it, fixed in the entries
  below. Routed to M1: the Rule text carries the definition, and the recount reads every attempt.
- 2026-11-22: The shared call hovers, waits, then sends an `XCUICoordinate.scroll` at the point the wait checked, so
  XCUI never picks the wheel's point (autonomous; depends on keeping M2). Converged in 1 pass, after the review's
  first pick, the element's own scroll, gave way: XCUI's point for the data table need not be the hover point. Routed
  to M2: the point comes from the clipped rectangle, and an event trace shows no move between settle and wheel.
- 2026-11-22: Clicks are left as they are, with a revisit hook on a click flake whose screenshot or report puts the
  click outside its target (autonomous). Converged in 1 pass.
- 2026-11-22: No outside-input detection. The Rule section and the `make test-app` and `make test-app-select` help say
  a local UI run needs the pointer and keyboard left alone (autonomous, addition: the help text). Converged in 1 pass.
- 2026-11-22: N comes from the entry's whole history, every attempt since the first sighting up to the fix, for every
  entry. For the launcher, 18 in 76, so 13 runs, in place of M1's 6 (autonomous; depends on the 95% target). Converged
  in 1 pass, after the review's first pick, the rate since the last change, gave way: it was mostly the 2026-11-21
  burst. The critic was given 18 in 102 from a window that began a day before the first sighting. Corrected to 76, the
  count drops from 17 to 13 and the ranking does not change.
- 2026-11-22: Fact: under the rate above, the launcher's 16 clean runs since the pointer change meet M1's count of 13.
  M1's remaining work is the Rule section and the launcher entry. Superseded by the rate entry below.
- 2026-11-22: Coherence review: "When an entry closes" now says clean CI runs, not clean CI `app` runs, so a package
  entry can close and the rule reads the same with UTERM-044's shards (autonomous). UTERM-046 joins Impacts, since the
  rule decides when its entries close. The Summary no longer calls the call-site question open.
- 2026-11-22: Routed from the coherence review to M1: a settle timeout restarts the count; a pass counts only from a
  job that ran in that attempt; N comes from CI attempts only; a Fixed entry seen again moves back to Potential. To
  M2: the launcher entry goes back to Potential on a wheel failure after M2, and the diff stays in test code. A new
  risk names M2's swap of a proven aim, and the trace risk says the local trace cannot prove CI's timing.
- 2026-11-22: Reopened "Which call sites move" once: `make check` now fails on an XCUI wheel outside the shared call,
  since without it the raw call stays the obvious path and a bypass shows only as a CI flake (autonomous, addition:
  one check script and one Makefile line). Converged in 1 pass. Routed to M2: the check ignores comments, matches
  split calls, exempts only the helper's call, and lands with the last moved site. Depends on keeping M2.
- 2026-11-22: Reopened "Which observed rate sets the count" once: N now comes from the lowest failure rate among the
  windows between the fixes the entry records (autonomous; depends on the 95% target). The whole history's rationale
  was backwards: when an earlier fix removed a frequent cause, older attempts raise the rate and shrink the count.
  Converged in 1 pass, on an option the critic proposed. The last two re-check passes then found design-level defects
  in its zero-failure window rule, and the entries below fixed them. The review's earlier figures were reconciled:
  from the first sighting to the pointer change, 18 failures in 76 attempts. Before the 2026-11-21 fix that is 12 in
  55, not the 7 the first brief gave. The launcher's count is about 15, from 3 in 15 attempts before "Wait for the
  launcher's last entry to come into view after a scroll". Its 16 clean runs meet it, by one, until M1's recount fixes
  the window boundaries. These figures are approximate. The review's tally may count a passing `app` job that a rerun
  carried from an earlier attempt, which inflates the attempt counts. M1's recount counts only jobs that ran in each
  attempt.
- 2026-11-22: Re-check fixes (autonomous; depends on the 95% target): a clean run now covers every test an entry's
  sightings name, so an entry seen in several tests, such as the `ScriptFixtures.finish` one, can close and cannot
  close on the wrong test. A window with no failure in k attempts gives N of k, later reverted. The rate rationale no
  longer claims the count never closes an entry early. The launcher entry goes back to Potential when M2 lands, until
  M2's count is met. These refine the lowest-window rate and the test-level clean run, and depend on keeping the
  closing rule's 95% target.
- 2026-11-22: Last re-check fixes, not re-checked (autonomous; depends on the 95% target): a window with no failure
  sets no N again, since it measured no cause and a zero window would have tripled M2's count over a cause no earlier
  window saw. An attempt in which only some of an entry's tests started, and none failed, is neutral. M2's count is
  M1's while the window from the pointer change holds no failure.
- 2026-11-22: Growth check: three passes each added counting cases that serve one requirement, the closing rule's 95%
  target. Kept for this review. The question of keeping, narrowing, or dropping that target goes to the user. Every
  entry from "What a clean run is" on that refines the count depends on the answer.
- 2026-11-22: A re-check confirmed that a failure-free window sets no N. It found two contradictions, both now fixed. A
  partial start is neutral only when each test that started passed, and a test that did not finish breaks the streak.
  M2's count equals M1's only while the window from the pointer change holds no failure. M1 also states the attempts
  that N counts and how a cancellation by a newer push counts. (autonomous; depends on the 95% target)
- 2026-11-22: Review gate: kept all. M2 and the 95% closing target stay, so the entries that depend on them stand.
  The carve-out for failures logged under another entry, the coordinate aim, and the additions stand. "Test code only"
  now reads "no product code changes", and the settle never waits on the outcome of the event it comes before. No
  decision gets an ADR. Status set to accepted.
- 2026-11-22: Scheduled as UTERM-045 M1 and UTERM-045 M2 in queue.md.
- 2026-11-24: Amended "Which observed rate sets the count" and M1's count. M1's recount read the launcher test's own
  `passed` and `failed` lines in every `app` job log, from the first sighting on 2026-11-15 through 2026-11-25T04:05Z.
  The review's figures were approximate tallies. From the first sighting to "Wait for the launcher's last entry to come
  into view after a scroll": 2 failures in 22 attempts. From there to "Scroll the short launcher either way the
  machine's wheel goes": 4 in 20. From there to "Settle the pointer on the launcher list before the scroll test's
  wheels": 3 in 19. The lowest rate is 2 in 22, so N is 11 and the count is 33. Since the pointer change, the test
  passed in 21 consecutive attempts. 5 of them came before "Poll UI test waits every quarter second instead of
  XCTest's second". So 12 clean runs remain. "Which observed rate sets the count" said: "By commit time they hold about
  3 failures in 15 attempts, 9 in 40, and 6 in 21. The lowest is 3 in 15, so N is about 5 and the count is about 15.
  M1's recount fixes the exact boundaries." M1 said: "about 3 failures in 15 attempts, so about 15 runs." Two readings
  are run best guesses. A head holds a fix when the tree CI tested holds it, which for a PR job is the merge of its head
  into its base. The history starts at the first sighting, inclusive. If it started at the test's first CI run instead,
  the first window would hold 2 failures in 32 attempts, and the count would be 48.
- 2026-11-24: Recount from the previous cutoff. One more `app` job finished: 138998184972, finished 2026-11-25T05:48Z,
  passed. Five other runs skipped the `app` job, so they are neutral. The streak is now 22 clean runs through
  2026-11-25T05:48Z. 11 clean runs remain.
- 2026-11-25: Recount from the previous cutoff. Three runs finished since 2026-11-25T05:48Z. Run 259, job 139008918170,
  skipped the `app` job. Run 260, job 139036554483, passed. Run 261, job 139049211184, skipped the `app` job. The
  streak is now 23 clean runs through 2026-11-25T07:27:48Z. 10 clean runs remain.
- 2026-11-25: M1's clean count split into M3 by amendment, as a run best guess. M1 had the count as a condition of
  DONE. The `/work-queue` run never pushes, so no CI run can happen inside it. M3 takes the consecutive-clean-runs
  bullet with its 33-run figure and the 5-runs note; the bullet that the launcher entry stays under Potential until the
  count is met; the bullet that a CI failure with the pointer inside the list sends the proposal to the user to retarget
  or retract; and the bullet that a CI failure in which the settle's own wait timed out or the pointer left the list
  after the settle restarts the count and reopens the aiming question. M1 keeps every bullet about the Rule section, the
  help text, and how the recount reads attempts. M1 is DONE. M3 is IN PROGRESS, since the recount itself updates the
  figures. M2 waits on M3. The Risks section now says M2 starts only after M3's clean count. M1's title read "The
  launcher change holds in CI".
- 2026-11-27: Recount from the previous cutoff, 2026-11-25T07:27:48Z. Ten clean attempts finished through
  2026-11-26T05:25:54Z, so the streak is 33 and meets the count. Clean, by run: 45672965577 attempt 1 and attempt 4.
  The test passed in both. Both failed on `QuestionsUITests.testEveryAnswerTypeReturnsItsShape`, which is logged under
  its own entry. The other clean ones: 45674064633 attempt 3, 45686673599, 45713785782, 45719243800, 45749818748, 45752629043,
  45755641410 attempt 1, and 45760228289. Neutral: 45672965577 attempts 2 and 3 and 45674064633 attempts 1 and 2,
  whose `app` jobs were cancelled before the test could have started. 45755641410 attempt 2 carried all three shard
  jobs from attempt 1, with the same start and finish times, so it counts once. 11 runs skipped the `app` job, among
  them 45568507167, the push at 2026-11-25T07:29:15Z. No log holds a failure of the launcher test. Every head holds the
  pointer change. The test ran in 6 unsharded `app` jobs, the 82nd of 215 tests. In the 4 sharded runs it ran in shard
  1 of 3, fourth or fifth, never first. Run best guess: four cancelled jobs have no log, since their logs return 404.
  Each ran 15:02 from start to finish. The test started 16:50 or later into the neighbouring jobs of the same PR
  (16:50 and 16:55), so a 15:02 job ended before the test could have started, and it is neutral. Had one been
  mid-test, the streak would have broken there.

## References

- `spec/flaky-tests.md`
- UTERM-044, which shortens each rerun a flake costs. Its "How the tests are divided" puts the launcher test third in
  the second shard, right after a cold start. A recount that spans 044's landing notes the landing in the launcher
  entry
