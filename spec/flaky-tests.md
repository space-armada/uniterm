# Flaky Tests

This document tracks UI and unit tests that fail without a code change. It lists potential flakes and records the
fixed ones.

## Rule

- A test that fails in a run and then passes when rerun alone is a potential flake. List it under "Potential".
- A test that fails again when run alone is a confirmed flake. Fix its cause in the test or the product.
- An entry moves to Fixed only with a fix commit and clean CI runs. For an entry seen once in N CI attempts, about 3N
  consecutive clean CI runs give a 95% chance of seeing it again if still present.
  - A clean run is one in which the entry's tests started on a head holding the fix and all passed. The entry's tests
    are every test its sightings name. Other failures in the same run do not matter.
  - An attempt in which the entry's test never started, such as a skipped job or one cancelled by a person or newer
    push before the test, neither counts nor breaks the streak.
  - A partial start in which only some of the entry's tests started and each one that started passed neither counts nor
    breaks the streak.
  - A test that started and did not finish, such as one cut off by a job timeout, a crash, or a cancellation mid-run by
    a newer push, is not clean. It breaks the streak.
  - A failure of one of the entry's tests that is logged under another entry, by its failure line and message, neither
    counts nor breaks the streak.
  - Each attempt of a rerun is its own run, ordered by when the attempt finished. A job a rerun carries from an earlier
    attempt counts once, only in the attempt that ran it.
  - N comes from the lowest failure rate among the windows between the fixes the entry records. A window begins at the
    first CI attempt whose head holds that fix. A commit that only adds a report does not split windows. N's
    denominator counts every CI attempt that ran any of the entry's tests, partial starts included. A window with no
    failure sets no N. An entry with no CI failure at all has no N and stays under Potential.
  - N counts CI attempts only. A sighting from a local run is logged and adds nothing to N.
  - An entry seen too rarely to reach its count stays under Potential, naming the change.
  - A run that fails with a settle's report closes nothing. It records a new cause on the entry.
  - A Fixed entry seen again moves back to Potential with the sighting.
- Each CI entry records whether the test ran first in its shard job, and the shard's logged selection. A shard job
  means the matrix job that ran one of the three UI test shards. When a test ran in a full local run, those fields say
  so instead.
- A sighting of a stalled event records which of its numbered events went unconfirmed, and which app was frontmost.
  XCTest sends each key or click as numbered events. It waits up to 5 s for the app to confirm each key event and each
  mouse up. A failed UI run keeps the evidence. A sighting whose run kept none says so.
  - The kept log is `.build/DerivedData-test/ui-test-kept-log.txt.gz` after `make test-app` or
    `make test-app-select`. A shard run keeps `ui-test-kept-log-shard-N.txt.gz` beside it. CI uploads that file with
    a failed shard's test results. The log holds `testmanagerd`'s line for each numbered event. An unconfirmed event
    reads "confirmed implicitly by confirmation delay timeout". The runner's test marks, issue marks, and frontmost
    lines share its clock.
  - A failing test's `.xcresult` carries a `frontmost-record.txt` attachment. It names the frontmost app at the test's
    start and each activation after.
  - A debug build writes an `input-recording` line for each event uniterm takes off its queue. A record matches
    `testmanagerd`'s line by its `source_userdata`, which is the event's number, and by its `type`. Its `source_pid`
    is `testmanagerd`'s pid. "Key 17 down" records as `type=keyDown keycode=17`. A modifier's down and up both record
    as `type=flagsChanged`, as in `keycode=55` for Command. A click's "Mouse up" records as `type=leftMouseUp`.
  - No record means AppKit never dequeued the event. Either it never reached uniterm, or it never left the queue. A
    record of an unconfirmed event means uniterm took it and its confirmation never came. A record also names the key
    window and the first responder at the moment uniterm took the event. AppKit merges queued moves, drags, and
    scrolls, so a missing record for one of those proves nothing. A press on the menu bar leaves no record either.
  - The app's `window_resigned_key` and `window_became_key` lines show another app's panel taking the keyboard while
    uniterm stays frontmost.
- A failure that reproduces reliably is a bug. File it under `spec/bugs/`.
- Never fix a flake with retries, longer timeouts, or weaker assertions. A wait may grow only when a measurement
  shows that one observation costs most of the old wait. The entry then records that measurement.
- A local UI run needs the pointer and keyboard left alone.

## Potential

### `QuestionsUITests.testEveryAnswerTypeReturnsItsShape`

Fixed by: "Wait for the form's focus before typing its answers" and "Give the Questions form its own Tab order"

- Seen: 2026-11-22, in the first CI `app` run of the PR that added it.
- Evidence: `QuestionsUITests.swift:266` read a null name where "Ada" was typed.
- Cause: the test typed as soon as the name field appeared. The form takes the keyboard a moment later, so the keys
  went nowhere.
- Fix: the test waits for the field to hold the keyboard before typing. `testANewFormTakesKeysAtOnce` still types
  as soon as the field appears, since how soon keys arrive is its claim. It shares the exposure.
- Seen again: 2026-11-25, in both CI `app` runs on the script tab numbers PR, and in 5 of 10 local runs on its head.
  The same 10 runs without that change all passed. That change sits nowhere on the test's path, so it shifts the
  timing only.
- Evidence: `QuestionsUITests.swift:278` read a null name. The whole outcome was null. A person watching a failing run
  saw "7-0.5" in the count field, an "Enter a number." error, and a disabled OK.
- Cause: the ratio field starts below the form's visible part. XCUITest scrolls the form, then clicks where it found
  the field. The click landed before the scroll took effect, so the ratio's keys went to the count field. OK stayed
  disabled, and no outcome came. The null name only reflected the missing outcome.
- Fix: the test moves between fields with Tab, and the form chains its own Tab order. Without that chain, Tab went
  wherever AppKit's default sent it, which changes with the Keyboard Navigation setting. With the fix, the script tab
  numbers PR's head passed 30 of 30 local runs.
- Checked: an event-logging monitor, a screenshot after typing, and the debug input recorder each hid the failure or
  changed it. Only a person watching an uninstrumented run saw the real one.
- Status: the count of clean CI runs is not yet set for this window.

### `DataViewerUITests.testEditFindExistsAndIsDisabledWithNoFile`

- Seen: 2026-11-07, once in a full suite.
- Evidence: `DataViewerUITests.swift:365` failed with "Invalid parameter not satisfying: point.x != INFINITY" when
  clicking Edit > Find. The test passed 6 of 6 alone.
- Suspected cause: state in the menu bar left by earlier tests in the suite.
- Checked: a closed menu is not the cause. With the Edit click removed, XCUITest opened the menu path itself and the
  test passed. A menu item has no frame when the app's menu bar is not on screen, so uniterm may not have been
  frontmost. That fits the lost-key entries above.
- Status: unresolved. The test now waits for the item to take a click, and the failure names the app's state, the
  frontmost app, and the focused element.

### `PaneTreeUITests.testFocusMovesWithTheKeyboardAndInputReachesOnlyTheFocusedPane`

- Seen: 2026-11-07, once in a full suite.
- Evidence: `PaneTreeUITests.swift:59` failed. The typed `echo "L:$((6*7)):"` never showed in the focused pane within
  20 s. The test passed 3 of 3 alone.
- Suspected cause: keys sent right after Cmd-Option-Left moved focus went nowhere. This is the same pattern as the fixed
  Cmd-W flake.
- Checked: `PaneAreaView.focus()` moves the focus mark and the first responder in one synchronous call. The test's
  wait for "focused" cannot run ahead of the responder, so a race inside the app is unlikely. Something outside the
  app taking the keyboard fits better, such as another session's UI run or a system prompt.
- Status: unresolved.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.

### `PaneTreeUITests.testReopenBringsBackTheClosedPaneFromItsDescription`

- Seen: 2026-11-07, once in a full suite, in the same run as the entry above.
- Evidence: `UnitermUITestCase.swift:142` found no `pane-2`. The test passed 3 of 3 alone.
- Suspected cause: the pane-opening key went nowhere, as in the entry above.
- Status: unresolved.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.

### `MapViewerUITests.testLauncherOpensAMapAndTheViewMenuSwitchesItsStyle`

- Seen: 2026-11-20, once, in a run of `MapViewerUITests` alone with 10 tests. It ran right after the go-to field
  failure above, whose paste also never landed.
- Evidence: `MapViewerUITests.swift:51` failed when the launcher did not appear within 5 s after Cmd-D. The same class
  order then passed 10 of 10, and the test passed 3 of 3 alone.
- Suspected cause: Cmd-D sent before the app was frontmost, as in the fixed
  `DataViewerUITests.testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAFile` entry. `waitForTerminal` should
  prevent that, so the cause is unconfirmed.
- Reruns: the same 5 class runs as the entry above. It passed in every one.
- Status: unresolved.

### `LayoutUITests.testQuitAndRelaunchRestoreTheSplitLayoutAndTheShellDirectory`

- Seen: 2026-11-20, once, in a full `make test-app` run of 175 tests.
- Evidence: `UnitermUITestCase.swift:249` failed after 30 s with "No matches found for Elements matching predicate
  'identifier BEGINSWITH "pane-"'". No pane showed after the relaunch. No uniterm crash report was written.
  `LayoutUITests` then passed 21 of 21 alone, with each of its 7 tests run 3 times.
- Reruns in order: `LaunchServicesOpenUITests`, `LauncherUITests`, and `LayoutUITests` ran together 5 times. Those
  are the classes that ran just before it in the full suite. The test passed in all 5 runs.
- Suspected cause: unknown. The run that saw it changed only the map applet and map tests.
- Status: unresolved.

### `TerminalLinkUITests` (both tests)

- Seen: 2026-11-17, during the UTERM-015 M6 work-queue run. At 01:00, both tests failed in one run. At 01:03, a
  three-iteration run failed 4 of 6: the relative-path test 3 of 3, and the hover test 1 of 3.
- Evidence: "no overlay with Command held over the path" (`TerminalLinkUITests.swift:62`, then `:77`), and "the
  message does not say why. It reads" with an empty status message (`:107`, then `:120`). The UI hierarchy showed the
  printed path in the terminal, an empty status message, and no overlay, so no link hover reached the app.
- Not reproduced: two later three-iteration runs with the debug `terminal-link` log streaming passed 12 of 12. The log
  showed each relative click refused as relative and each absolute click opened. Between the failing and passing
  runs, only the test's pointer moves and the debug logging changed.
- Known mechanism, not proven to be this one: libghostty drops a pointer move within 1 px of its stored position, so
  a hover that starts on the target sees no link. The test now moves across cells before it hovers. A real pointer
  moved by a person during the run would also break the synthesized hover.
- Seen again: 2026-11-21, locally, on `main` and on a branch that touches no terminal code. The relative-path test
  failed 1 of 2 fresh launches on `main` and 3 of 3 on the branch. It then failed 5 of 5 on `main` with the debug log
  on.
- Evidence: each failing log has `flags mods=8` when the test sets Command, then `pointer` and `press` lines with
  `mods=0`. The click reached libghostty without Command, so it was a plain click, and nothing refused a link. In one
  run, 179 `pointer` lines arrived during the test's 2 s idle wait. They wandered up to 200 px on a curving path.
  XCTest sent no events then.
- Cause: a physical mouse or trackpad moved during the runs. Real input events carry the real modifier state, so
  they drop the synthesized Command. They also move the pointer off the target. No CI run has failed this test.
- Status: cause found. Neither the test nor the product is at fault. Keep the pointer and keyboard still during a
  local UI run.

### `BrowserUITests.testCommandWClosesTheTabAndCommandShiftTReopensIt`

- Seen: 2026-11-12, once, as the first test of a full `make test-app`.
- Evidence: `BrowserUITests.swift:166` failed with "Cmd-Shift-T brought no tab" after 49.8 seconds. The other 157
  tests passed. `BrowserUITests` then passed 12 of 12 alone, this test in 11.6 seconds.
- Suspected cause: a cold first launch of WebKit at the start of the suite. Not confirmed.
- Status: unresolved.

### `ControllerConsentUITests`, several tests, after the strict and unsafe modes landed

- Seen: 2026-11-15, in four local runs during the work-queue run that added strict and unsafe script modes. Each run
  failed a different test, and every test passed in at least one other run of the same code:
  - `testAPlainScriptsQuestionNamesItsRun`, `testControllersAndPermissionsShowsAndRevokesTheApproval`, and
    `testThePanelAllowsOnceAndDeniesAReview` failed in one five-class run. All three passed together when run alone.
  - `testThePanelTrustsAVersionThatThenRunsWithoutAsking` failed with "the window never showed the review. The shell
    wrote none. Standard output: none Standard error: none". The typed shell line never ran.
  - `testADeclaredFilesReviewAndApprovalReachThePanelAndTheWindow` exceeded its 1-minute allowance as the first test of
    a class-only run.
- Evidence: the class passed 7 of 7, four times, before the change. The change made each test's run wait for a review,
  and added two tests. The failure messages now report what the shell and the command wrote.
- Suspected cause: lost keystrokes or focus races between app instances, or a system prompt holding the first test.
  Not confirmed, and not reproduced on the commit before the change.
- Seen again: 2026-11-18, in the CI `app` rerun of PR #67. `testAPlainScriptsQuestionNamesItsRun` passed every panel
  step, then `ControllerConsentUITests.swift:379` read `""` where `exit=0\n` was expected, 0.5 s after Deny.
- Partial fix: "Wait for a status file's whole line before reading it". The shell's `echo ... > file` creates the file
  empty before it writes, and `waitForFile` returned whatever it read first. It now waits for the line's newline. That
  answers an empty read only. The other failures above carry other messages.
- Seen again: 2026-11-18, `testAPlainScriptsQuestionNamesItsRun` was the only failure of 172 in a full `make test`.
  It failed at `ControllerConsentUITests.swift:352` with "the window never showed the review. The shell wrote none".
  The class then passed 9 of 9 alone on the same tree. That tree changed only which exec driver requests need a
  remote-controlled pane, which this script path does not reach. The partial fix above does not cover it. The typed
  shell line never ran, so no status file appeared.
- Seen again: 2026-11-21, locally, in a run of `ControllerConsentUITests` alone on a tree that changes no app or UI
  test code. `testThePanelTrustsAVersionThatThenRunsWithoutAsking` ran past its 1-minute allowance.
  The trust, the close of Pending Requests, and the click on the terminal all passed. The test then typed its second
  `sh` line at 20.7 s, and no UI step followed for the remaining 40 s. The other 8 tests of the class passed.
- Seen again: 2026-11-21, locally, in the next run of `ControllerConsentUITests` alone.
  `testAnUnsafeReviewOffersThreeChoicesAndNoTrust` failed at `ControllerConsentUITests.swift:414` with "the review
  never reached the panel". The pending-permissions indicator showed at 3.7 s, so the script ran and asked. Pending
  Requests then opened, and its first row never appeared in 30 s. The test passed 3 of 3 alone right after, on the
  same tree. That run typed script paths through a `.zshrc` variable. This class keeps the fixture's `.zshrc`, so the
  variable was set, as the indicator shows.
- Seen again: 2026-11-22, locally on main, in a run of the five classes up to `DataViewerUITests`.
  `testAPaneCallQuestionShowsTheRunsPID` failed at `ControllerConsentUITests.swift:139` with "the terminal did not
  take the keys, so typing would beep". That run made three passes, and the class failed once.
- Seen again: 2026-11-22, in a full local `make ci` on a tree that adds the Questions applet.
  `testASignedFilesReviewOffersTrustThisIdentity` failed at `ControllerConsentUITests.swift:126` with
  "pending-requests-window did not close". It passed 3 of 3 alone right after, on the same tree.
- Status: unresolved.

### `PendingRequestsUITests.testADenialReachesTheProgramAndClearsTheIndicator`

- Seen: 2026-11-15, once, in a five-class local run. It passed in the run before.
- Evidence: "Unable to find hit point for ScrollView, {{20.0, 749.0}, {739.0, 180.0}}".
- Suspected cause: the scroll view was covered or still moving when the test clicked it. Not confirmed.
- Status: unresolved. Both row clicks into the Pending Requests panel now wait for the row to take a click, and the
  failure names the app's state, the frontmost app, and the focused element.

### `WindowsUITests.testCommandWClosesOnlyTheKeyWindow`, after its fix

- Seen: 2026-11-15, once in a full `make test-app` run during the UTERM-007 M5 work-queue run, the only failure of 165.
- Evidence: `WindowsUITests.swift:120` failed: `echo "K:$((6*7)):"` produced no output in 20 s after a click on the
  first window. That is the full-suite symptom the fix in "Fixed" below names. `WindowsUITests` passed 6 of 6 alone
  right after, on the same tree.
- Status: the earlier fix covered the foreground read. This symptom came back once. Cause unknown.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.

### `WindowsUITests.testClosingTheLastWindowKeepsTheAppRunningAndCommandNOpensAgain`

- Seen: 2026-11-21, locally, on a branch that touches no window code. It failed in a full `make test-app` run and on
  the first of three iterations alone. Both failures came in the same few minutes as the outside pointer input that
  the `TerminalLinkUITests` entry above names.
- Evidence: "the app left the foreground" at `WindowsUITests.swift:95`, about 10 s after Cmd-W closed the last
  window. The test then passed 4 of 4 fresh launches, and `main` passed 5 of 5.
- Suspected cause: the same outside input, such as a real click that moved focus to another app. Not confirmed.
- Status: unresolved.

### `ExecPaneUITests.testWindowShortcutsWorkWhileTheDriverStalls`

- Seen: 2026-11-15, once in a filtered run of five UI classes during the UTERM-007 M5 work-queue run, the only failure
  of 20 tests.
- Evidence: `ExecPaneUITests.swift:185` failed with "Cmd-D did nothing while the driver stalled". The trail showed the
  app slow throughout: 30 clicks on Next took 13.37 s, and Cmd-D took 15.22 s. It then passed 3 of 3 alone, and its
  class passed whole, on the same tree.
- Status: unresolved. That run changed the exec wire's hello decoding and moved the exec protocol to 4. It also
  revalidates pending replies when remote control turns on. Neither was ruled out by a run on the base commit.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.

### `ControllerRunUITests.testTheBundledCommandRunsAVerifiedPackageAndNotAChangedOne`

- Seen: 2026-11-18, once in a full `make test` run at the start of a bug sweep. It was the only failure of 138 UI
  tests.
- Evidence: the test hung in `runInTerminal`. Typing the `sh` command into the terminal took 18 s. The next wait for
  the app to idle never returned, and the test hit its 60 s allowance. It then passed 3 of 3 alone. It also passed with
  `ControllerConsentUITests` run first, as in the full suite, on the same tree.
- Status: unresolved. The app was slow before the hang, much like the `ExecPaneUITests` entry above. No crash report
  from uniterm appeared in that window.
- Next sighting: note what ran just before it, and whether the app was slow in earlier tests of that run.

### `ScriptHostAPITests.testOpenTabCarriesItsArgumentsToTheApp`

- Seen: 2026-11-18, once, in a local `make ci-package` run for PR #67 while another test run loaded the machine.
- Evidence: the test ran past its 120 s limit. A sample showed `ScriptFixtures.finish` waiting, with the listener idle
  in its accept loop. The class then passed 5 of 5 alone at about 0.1 s per test, and the full rerun passed.
- Suspected cause: unknown. PR #67 changed the listener, and whether that plays a part is not settled.
- Seen again: 2026-11-21, in the CI `package` rerun of PR #81, which changes only a doc comment in the script host.
  `ScriptHostAPITests.testEveryFunctionRejectsBadArgumentsBeforeTheAppHearsOfThem` ran past its 120 s limit. The
  sample showed `ScriptFixtures.finish` blocked in `waitUntilExit`, and no child of `xctest` was still alive. So the
  helper had exited, and its exit was never seen. The first `package` run of the same head passed this test.
- Seen again: 2026-11-21, in a local `make ci` of a landing batch that changes no script host code.
  `ScriptLintCommandTests.testUsageMistakesAreRefusedWithTheUsageStatus` ran past its 120 s limit, with the sample
  again showing `ScriptFixtures.finish` blocked in `waitUntilExit`. A rerun of the same tree passed its package tests.
- Seen again: 2026-11-23, in a local `make test-package` during a bug sweep, checking a fix that changes only WindowKit
  and an AppletKit doc comment. `ScriptHostAPITests.testEveryFunctionRejectsBadArgumentsBeforeTheAppHearsOfThem` ran
  past its 120 s limit. The sample again showed `ScriptFixtures.finish` blocked in `waitUntilExit`. `ScriptHostTests`
  does not depend on WindowKit. The full rerun of the same tree passed all 3214 tests.
- Change: UTERM-046 M2. The script fixture spawns each helper with `posix_spawn` and is its only reaper. One thread
  per helper waits with `waitid` and `WNOWAIT`, sets the reaped flag under a lock, and then reaps with `waitpid`.
  `finish` waits on that reap, not on Foundation's exit report, and returns at once for a helper already reaped.
  Every caller of `start` and `finish` now runs its helper this way, including the nine that built their own
  `Process`.
- Which sightings it explains: the 2026-11-21 CI sighting. It recorded that no child of `xctest` was alive, so the
  helper had been reaped and Foundation never reported it. The fixture no longer waits on that report. If another
  reaper took the helper, the wait now fails the test with an error that names another reaper.
- The other two `waitUntilExit` sightings recorded no process listing. They are explained only if their helper had
  been reaped. A helper that was still running would be ended by the fixture's 60 s and 70 s deadlines, as the old
  watchdogs already ended it. The first sighting shows only a wait, so the same holds for it.
- After the change, `ScriptHostTests` passed 358 tests, with 3 skipped, and the 3 shipped-command tests passed under
  `make test-helper-sandbox`. No test reproduced Foundation missing an exit, so the fixture's tests pin the fix, not
  the bug.
- Status: unresolved. It stays under Potential until it meets the closing rule in the Rule section.

### `ExecPaneUITests.testARestoredExecPaneRunsOnlyAfterValuesAndApprovalThenDrivesTheApplet`

- Seen: 2026-11-18, once, in a filtered `ExecPaneUITests` run during a bug fix that split the driver's
  disconnected-pane refusal.
- Evidence: it failed with "the panel did not show the launch's argv", a Pending Requests panel check. It passed when
  rerun alone once, on the same tree. The fix changed only which driver requests need a remote-controlled pane. It did
  not touch the launch panel.
- Status: unresolved. The change under test was not ruled out by a run on the base commit.

### `CommandPaletteUITests.testAProgramTitleShowsNeutralizedAsATab`

- Seen: 2026-11-18, once in a full `make test` run right after a rebase onto upstream main. It was the only failure of
  172 UI tests.
- Evidence: `CommandPaletteUITests.swift:290` failed with "the palette never showed". Typing Cmd-K took 20 s, from
  3.91 s to 24.36 s. The palette did not appear in the 5 s wait after it. The test then passed 3 of 3 alone on the same
  tree.
- Seen again: 2026-11-22, in the same full local run as the third `ControllerConsentUITests` sighting of that day.
  It failed at `CommandPaletteUITests.swift:294` with "the title was not neutralized", and passed 3 of 3 alone
  right after.
- Seen again: 2026-11-22, in a local `make test-app-select UI_TESTS=CommandPaletteUITests` run while landing the
  palette's Control-K and Control-A keys. It was the class's first test. It failed at `CommandPaletteUITests.swift:353`
  with "the title was not neutralized", after 10 s of row checks. It passed 3 of 3 alone on the same tree.
- Status: unresolved. A single keystroke that takes about 20 s also shows in the `ControllerRunUITests` and
  `ExecPaneUITests` entries above. The app may stall now and then in a long run. That is not confirmed.
- Next sighting: when a key stalls, as Cmd-K did, the kept log shows which of its four numbered events timed out. The
  frontmost lines and the key-window lines show whether another app or a panel held the keyboard. The app's records
  show whether uniterm dequeued each timed-out event. `testmanagerd`'s `Got NSAccessibilityEventProcessedNotification`
  lines from uniterm's pid show whether its event loop ran through the stall. That tests the guess that the app stalls.
  When nothing stalls, as in the two later sightings, the records name the first responder when uniterm took each
  typed key.

### `CommandPaletteUITests.testChoosingABackgroundTabSelectsItAndTheKeyboardFollows`

- Seen: 2026-11-22, in the class run right after the sighting above, on the same tree.
- Evidence: `CommandPaletteUITests.swift:323` failed with "the background tab was not listed", after 10 s of row
  checks. The test typed its `printf` 1.6 s after launch, before any prompt showed. The class then passed 2 of 2 on
  that tree and 2 of 2 on upstream main. The change under test reroutes only Control-K and Control-A while the
  palette's field has the keyboard, and the test sends neither.
- Status: unresolved. Like the entry above, the row for a tab a program titled never showed. Both tests type the
  title before the shell is shown to be ready.

### `DockedPaletteUITests.testTheTopStripSitsInTheTitleBarRowAndTheOverlayOpensAwayFromTheEdge`

- Seen: 2026-11-18, once in a full `make test` run that set the baseline for a bug sweep. It was the only failure of
  172 UI tests.
- Evidence: `DockedPaletteUITests.swift:135` failed with "Failed to get matching snapshot: No matches found" for
  `command-palette-results`. In the top-docked half, Cmd-K showed the results overlay at 2.83 s. The overlay was gone
  when the test read its frame at 3.13 s, and two retries did not find it. The test then passed 3 of 3 alone on the
  same tree.
- Status: unresolved. Something closed the overlay right after it opened. A lost key window would close it, which fits
  the lost-key entries above. That is not confirmed.

### `StatusBarUITests.testClickingTheDismissControlClearsAnError`

- Seen: 2026-11-19, once in a full `make test` run for a text viewer fix that does not touch the status bar. It was the
  only failure of 172 UI tests.
- Evidence: `StatusBarUITests.swift:119` failed with "the error stayed on the bar". The click on `status-dismiss` fell
  back to the element's center point at 2.89 s, and synthesizing it took until 8.20 s. The message then stayed on the
  bar through the whole wait. The test passed 3 of 3 alone on the same tree.
- Status: unresolved. A synthesized event that stalls for seconds also shows in the `CommandPaletteUITests`,
  `ControllerRunUITests`, and `ExecPaneUITests` entries above. Whether the click reached the control is not known.
- Next sighting: the kept log shows whether the click's mouse up timed out. XCTest waits on no other event of a click.
  The bar dismisses on the mouse down, which XCTest sends without waiting. The app's record of that mouse down says
  whether uniterm took the press. Its `location` says where in the window the press landed. The bar answers every hit
  test inside it, so the record's hit view reads `status-bar`, not `status-dismiss`. The frontmost lines show whether
  another app was in front.

### `ScriptRunCommandTests.testSubprocessAndNetworkAreDeniedByDefaultAndGrantedByTheirNames`

- Seen: 2026-11-19, once, in the first CI `package` run of PR #74, which changes only the exec driver's member commands.
- Evidence: `ScriptRunCommandTests.swift:176` failed with "XCTAssertEqual failed: ("13") is not equal to ("0")". The
  `denied-subprocess` script, run with the `subprocess` grant, exited 13 with empty standard error. The same test
  passed in `make ci-package` locally on that tree, in CI on PRs #72 and #73, and in the rerun of the failed job.
- Suspected cause: 13 is SIGPIPE's number. The script or its `/usr/bin/true` child may write to a pipe that already
  closed. Not confirmed.
- Status: unresolved.

### `TerminalSessionIntegrationTests.testShellSeesTheNewSize`

- Seen: 2026-11-06, twice in CI's `build` job, on PRs #21 and #29. Neither PR changes terminal code. Found later by
  reading CI logs, not at the time.
- Evidence: both runs failed with "timed out waiting for stty to report S:11x49" after about 20 s. The rerun of each
  failed job passed on the same head.
- Suspected cause: unknown. No CI run since 2026-11-06 has failed it.
- Status: unresolved.

### `BrowserUnsentInputTests.testEditsInASubframeMarkTheTabAndOnlyThatFrameClearsIt`

- Seen: 2026-11-08, once in CI's `build` job, on PR #34, which changes only the palette. Found later by reading CI logs,
  not at the time.
- Evidence: it failed with "timed out waiting until the main frame reported its edit" after 16 s. The rerun of the
  failed job passed on the same head.
- Seen again: 2026-11-25, once in CI's `package` job on PR #117, at 04:38:45 UTC on 2026-11-26. Its first attempt
  failed and the rerun of the failed job, attempt 2, passed on the same head. The test is a package test, so it did not
  run in a shard job, and no shard selection applies.
- Evidence: `BrowserUnsentInputTests.swift:196` failed with "timed out waiting until the main frame reported its edit
  and its clear" after 19.049 s. It was the only failure in that job. The test passed in 0.46 to 0.70 s in the
  `package` jobs of the other three pull request runs after the sharding landed, and in the rerun. Its message now also
  names the clear, so it may come from a different wait than the 2026-11-08 sighting. That is not confirmed.
- Suspected cause: unknown. No cause is guessed from two sightings.
- Status: unresolved. Two sightings in CI and no fix, so it sets no N and stays under Potential.

### `LauncherUITests.testAShortPaneKeepsTheFilterBoxAndScrollsToTheLastEntry`

- Seen: 2026-11-15, 2026-11-18, and 2026-11-19, once each in CI on PRs that did not touch the launcher. On
  2026-11-21 it failed 5 of 10 CI `app` runs, 2 of them on main.
- Seen locally: 2026-11-20, once in 5 runs of `LaunchServicesOpenUITests`, `LauncherUITests`, and `LayoutUITests`
  together, with the same message. That run changed only the map applet and map tests. On that machine the first
  wheel goes down, so the scroll direction does not explain this sighting. Its cause is not known.
- Evidence: `LauncherUITests.swift:199` failed with "the scroll wheel did not scroll the list", with uniterm frontmost
  and the launcher's filter box focused. The failure screenshot showed the list still at its top. Waiting for the list
  to settle did not help. Locally it passed 15 of 15, and 10 of 10 with legacy scrollers forced as CI shows them.
- First suspected cause: the test sent one wheel of -1000 to a list that starts at the top. Which way that moves the
  list follows the machine's scroll direction setting, and CI runners differ in it. When the wheel went up, the list
  could not move. Flipping the sign to +1000 on a local machine failed the first run with CI's message.
- Tried: "Scroll the short launcher either way the machine's wheel goes". The wheel goes the other way when the first
  one leaves the last entry out of view. A list that scrolls neither way still fails. After that change, the launcher
  tests passed 7 of 7 locally, and 3 of 3 with the two wheels swapped.
- Seen again after that change: 2026-11-21, at `LauncherUITests.swift:209`, the assertion after both wheels. It failed
  CI on the merge of #82 into main, which carried the change, and on the first `app` runs of #83 and #87. Neither PR
  touches the launcher. #83's rerun passed. So the scroll direction is not the whole cause.
- Evidence: #83's CI step log shows both wheels sent to the launcher's only scroll view, 80 pt tall. Its screenshot
  before the wheels shows the list at its top, as expected. No screenshot was kept after them.
- Seen again: 2026-11-22, in the first CI `app` run of #90, with the new report. The focused list's scroller read 0
  before and after both wheels, and its frames never changed. The screenshot after the first wheel shows the middle
  pane's launcher scrolled to its last entry, and the one before the wheels shows it at its top. The first wheel went
  to the middle pane's list. In #83, two of seven snapshots show the focused list moved 84 pt, so a wheel can also
  land partly on the right list.
- Suspected cause: a wheel goes to whatever is under the pointer when it is delivered, and the pointer had not yet
  reached the focused list. A wrong-pane lookup does not fit, since the same lookup gave the focused list's frame just
  before and after the first wheel. A local run that left the pointer over the middle pane first still passed, so the
  race does not show on this machine.
- Tried: the pointer now goes to the focused list's center, and the test waits until it is inside the list before any
  wheel. The report also gives the pointer's position. If it fails again with the pointer inside the list, this cause
  is wrong.
- Recount through 2026-11-25T05:48Z, from the first sighting on: 2 failures in 22 CI attempts up to "Wait for the
  launcher's last entry to come into view after a scroll", 4 in 20 up to "Scroll the short launcher either way the
  machine's wheel goes", and 3 in 19 up to "Settle the pointer on the launcher list before the scroll test's wheels".
  All 9 failures are wheel failures, by their message "the scroll wheel did not scroll the list".
- The lowest rate is 2 in 22, so N is 11 and the count is 33. Since the pointer change, the test passed in 23
  consecutive CI attempts through 2026-11-25T07:27:48Z. 5 of them came before "Poll UI test waits every quarter second
  instead of XCTest's second". Four `app` jobs in that span were cancelled before the test started, and two were
  skipped, so they neither count nor break the streak.
- Method: the test's own `passed` and `failed` lines in every `app` job log, by attempt. A fix is held when the tree
  CI tested holds it, which for a PR job is the merge of its head into its base.
- Status: unresolved until 10 more clean CI runs reach the count of 33.

### `WindowsUITests.testCommandNOpensASecondWindowWithItsOwnShell`

- Seen: 2026-11-21, once, in a full local `make test-app` run of 176 tests, the run that moved UI test waits to
  quarter-second polling. It was the only failure.
- Evidence: `UnitermUITestCase.swift:118` failed when the second window's terminal never appeared. Synthesizing Cmd-N
  took 20 s, from 0.51 s to 20.73 s, and no second window opened in the 15 s after. With the faster waits, Cmd-N went
  out about half a second after launch, once the first prompt showed and the app was frontmost. `WindowsUITests` then
  passed 30 of 30, each test 5 times, on the same tree.
- Status: unresolved. A synthesized event that stalls for seconds also shows in the `CommandPaletteUITests`,
  `ControllerRunUITests`, `ExecPaneUITests`, and `StatusBarUITests` entries above. Whether a key sent that soon after
  launch makes it likelier is not known.
- Next sighting: the kept log shows which of Cmd-N's four numbered events timed out. The app's `Recording input` line
  marks its launch. The gap from it to Cmd-N's first event says how soon after launch the key went out. The app's
  records show whether uniterm dequeued each timed-out event, and which window was key. The frontmost lines and the
  key-window lines show whether another app or a panel held the keyboard.

### `CommandPaletteUITests.testATabThatClosesWhileThePaletteShowsDisappearsFromTheList`

- Seen: 2026-11-22, once, in a full local `make ci` run on a tree that adds the Questions applet and changes no
  palette code. It was one of 5 failures of 203 UI tests.
- Evidence: `CommandPaletteUITests.swift:319` failed a bare `XCTAssertTrue`. The test passed alone right after, on the
  same tree.
- Status: unresolved.

### `MapViewerUITests.testProgramPinsReturnOnReopenAndAreAnnouncedAfterARelaunch`

- Seen: 2026-11-22, once, in the same full local run as the `CommandPaletteUITests` entry above.
- Evidence: `MapViewerUITests.swift:489` failed with "a live run shows the earlier-run segment". The test passed alone
  right after, on the same tree.
- Status: unresolved.

### `MapViewerUITests.testTheStyleSurvivesARelaunchAndAnUnknownStyleShowsStandard`

- Seen: 2026-11-22, once, in a local run of the four viewer classes and `OpenPanelUITests`.
- Evidence: `MapViewerUITests.swift:160` failed a bare `XCTAssertTrue`. Apple's TV app had started 9 s before the
  first test, from outside the run. In the same run,
  `DataViewerUITests.testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAFile` failed with TV frontmost and uniterm
  in the background. The next two passes of the same classes passed 98 of 98.
- Suspected cause: another app took the front during the test. Not confirmed.
- Status: unresolved.

### `BrowserHungProcessTests.testClosingASpinningTabEndsItsProcessWhenTheBoundRunsOut`

- Seen: 2026-11-21, once, in the first CI `package` run of #91, which changes only a UI test and this file.
- Evidence: it failed at `BrowserHungProcessTests.swift:178`, "timed out waiting until the closed tab's process ends",
  and at line 294, where the signal log was empty: `[] is not equal to [12101]`. So the watch sent no signal.
- Suspected cause: the test gives the spinning page 0.3 s of real time, and the watch signals only a page that used at
  least half a core over it. On a loaded runner the page can get less, and the watch then rightly sends nothing. Not
  confirmed.
- Measured before the change: 2026-11-25, on a 14-core Apple silicon Mac. The test recorded the watch's two live
  readings. It also read the closed process's scheduling state at the close and at the fire.
  - Over the test's 0.3 s window, the watch read a share of 0.989 of a core on the idle machine. With a busy loop per
    core it read 0.966 for 14 loops in the test process, 0.987 for 14 separate processes, and 0.997 for 42 of them.
  - Over a 10 s window, the product's bound, it read 0.9999 idle, 1.000 with 14 loops, and 0.9994 with 14 processes.
  - In every run, at the close and at the fire, `proc_pidinfo` read the task's priority as 31 and its spinning
    thread's as 47. `getpriority(PRIO_DARWIN_PROCESS)` read 0, so Darwin did not run it in the background. Its Darwin
    role read UI focal. In three loaded runs, the thread's current priority read 0 at the close, before its loop had
    used the core. It read 47 at the fire.
  - No run read a share under half a core, and no priority dropped after the close. The loops ran at default priority,
    below the page's 47. Even 42 loops at user-interactive QoS in the test process left the page 98% of a core. The CI
    failure did not reproduce, so its cause stays unconfirmed.
- Change: UTERM-046 M1, in "Feed the closed-tab browser tests a derived busy sample". The closed-tab tests read the
  page through a sample derived from the live one. It keeps the live start time, time taken, and nil for a process
  that is gone. Only the processor time is replaced, by the time taken, so the page always reads as one full core. The
  tests fire the bound right after the close, with no window. A reading no later than the one before it fails the
  test, so a skipped watch cannot pass a test that expects no signal. The live-sample test now checks its units
  against independent readers instead of timing a spinning page.
- After the change, the class passed 9 of 9 on the idle machine, with 14 and with 42 busy loops in the test process,
  and with 14 busy processes. The failure never reproduced locally, so the test pins the fix, not the bug.
- Status: unresolved. It stays under Potential until it meets the closing rule in the Rule section.

### `BrowserUITests.testCommandLFocusesTheAddressBar`

- Seen: 2026-11-22, once, in a full local `make ci` on a tree that adds the Questions applet and changes no browser
  code.
- Evidence: `BrowserUITests.swift:55` failed a bare `XCTAssertTrue`. The test passed 3 of 3 alone right after, on the
  same tree.
- Status: unresolved.

### `ImageViewerScrollTests.testScrollMovesTheImageTheWayAScrollViewMovesItsDocument`

Earlier fix: "Wait for the reference scroll view to move in the image viewer scroll test"

- Seen: 2026-11-08, once in CI on a PR that changed no image viewer code.
- Evidence: the first case, a precise scroll of 0,40, failed "no oracle". The reference scroll view had not moved, so
  the test also read the image's correct pan as wrong. Run alone, it failed 1 of 20 before the fix.
- Cause: a fresh scroll view applies its first scroll on a later run loop pass, not inside `scrollWheel(with:)`. The
  test ran the run loop for a fixed 0.05 s and then read the scroll view once. Under load, that pass had not run yet.
  With no wait at all, the test failed every time, on that first case only. The image viewer itself was right.
- Fix: the test now runs the run loop until the scroll view leaves its starting point, with a two-second bound. A scroll
  view that never moves still fails the "no oracle" check. After the fix, it passed 20 of 20 alone.
- Seen again: 2026-11-22, once, in a local `make ci-package` of a batch that changes only a script host test. The
  first case of the 0,-40 precise scroll failed "no oracle", as before the fix: the reference scroll view had not
  moved within the two-second bound. The test then passed 20 of 20 alone on the same tree.
- Status: unresolved. The earlier fix does not cover this sighting.

### `ShortcutOwnershipUITests.testARemapOntoAnAppletKeyWinsAndWarnsOnce`

- Seen: 2026-11-25, once, in the first CI `app` run of #109. That PR changes map, viewer, browser, and terminal tab
  code, and no palette or shortcut code.
- Evidence: `ShortcutOwnershipUITests.swift:132` failed: the palette never went away after Escape. Synthesizing
  Escape took 5.09 s, from 1.80 s to 6.89 s into the test, where Cmd-T took 0.16 s. Its check for interrupting
  elements took 0.25 s, against about 0.03 s for every other event in the test. After the stall, the palette check
  answered every 0.57 s until the wait ran out at 17 s, so the app was not hung. The whole class then passed 7 of 7
  locally on the same head, the rerun of the CI `app` job passed, and the test passed 50 of 50 alone locally with
  `-run-tests-until-failure`.
- Seen again: 2026-11-25, in a local run of the test alone with `-test-iterations 15 -run-tests-until-failure`. Three
  of nine iterations stalled. Escape took 15.2 s in the sixth and Cmd-T 5.1 s in the seventh, and both passed. In the
  ninth, Cmd-T took 10.1 s and the test failed at `ShortcutOwnershipUITests.swift:129`, "the remapped key did not
  win". `testmanagerd`'s log for the ninth shows Command down and Command up confirmed within milliseconds, and the T
  down and T up each "confirmed implicitly by confirmation delay timeout of 5.00s". uniterm sent `testmanagerd` other
  event notifications about every 8 ms through those 10 s, so its event loop ran. In the seventh, Command down timed
  out and the T events were confirmed.
- Reruns: 2026-11-25, 45 local runs of the test alone on the same machine, with UTERM-060's in-app record built. None
  stalled, and `testmanagerd` logged no confirmation timeout. With recording on, 15 ran as separate
  `make test-app-select` runs and 15 as one run of `-test-iterations 15`. With recording off, 15 more ran as one run of
  `-test-iterations 15`. The earlier run stalled in 3 of 9 iterations, so the rate fell in both conditions. These runs
  cannot show whether recording changes it. No T event went unconfirmed, so whether uniterm records one stays open for
  the next sighting.
- Suspected cause: XCTest sends each key as numbered events and waits up to 5 s for the app to confirm each one. Each
  stall is that window running out for one or more events, and the effect of an unconfirmed key never came. Escape
  closes the palette only through its field's `cancelOperation`, and the palette sets that field as first responder
  before Cmd-T returns. This matches the stalled single events in the `CommandPaletteUITests`, `StatusBarUITests`, and
  `WindowsUITests` entries. Not confirmed: why the events went unconfirmed. The CI run kept no `testmanagerd` log.
- Status: unresolved.
- Next sighting: the kept log shows which of the stalled key's numbered events timed out. The frontmost lines and the
  key-window lines show whether another app or a panel held the keyboard. For each timed-out event, the app's records
  show whether uniterm dequeued it, and which first responder held the keyboard then. UTERM-060 M5 reads this entry's
  next Cmd-T stall. It records here whether uniterm recorded the unconfirmed T events.

### `DataViewerUITests.testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAFile`

Fixed by: "Wait for the app to be frontmost before UI tests type, and paste open-panel paths"

- Evidence: alone, it failed 1 of 6 at `waitForExistence` on the launcher after Cmd-D. The key never took effect.
- Evidence: in a full suite, it failed at the go-to field check. The typed temp path had become a neighbouring
  container's path. The `dev.uniterm.app.UITests.xctrunner` component turned into `dev.uniterm.UITests.xctrunner`.
- Cause of the first failure: the test sent Cmd-D before the app was frontmost. A synthesized key event goes nowhere
  then. The app never deactivates itself, so the race is in the test.
- Cause of the second failure: the open panel's go-to field autocompletes each path component while text is typed.
  Sibling folders that share a prefix make that rewrite the path.
- Fix: `waitForTerminal` now waits for the app to be frontmost, and activates it once if it is not. The test pastes
  the path instead of typing it, so the field has no keystrokes to autocomplete. It still checks the field's value.
- Seen again: 2026-11-26, once, in a full local `make test` run of 213 UI tests on `agent/petunia`, at "Say
  UTERM-061's stable palette list has landed". It ran mid-class in `DataViewerUITests`, not first.
- Evidence: `UnitermUITestCase.swift:546` failed after 36.7 s with "the panel never selected sales.csv. The app is in
  the background. The frontmost app is Google Chrome". That is a later wait than either earlier failure. The kept log
  shows event 177863, a Shift key down at 15:01:18, confirmed only by the 5 s timeout. The frontmost lines show Google
  Chrome activating at 15:01:30 and 15:01:46, Finder at 15:01:49, and Chrome again at 15:01:51. Whether a person or the
  run caused those activations is not known. The test passed alone right after, on the same tree.
- Status: unresolved. The sighting moves this entry back from Fixed.

### `LaunchServicesOpenUITests.testADeniedOpenFromAnotherProgramOpensNothingAndSaysSo`

- Seen: 2026-11-26, once, in the same full local run as the `DataViewerUITests` sighting above. It ran mid-class, not
  first.
- Evidence: `LaunchServicesOpenUITests.swift:57` failed after 33.7 s with "the question never reached the panel". The
  Pending Requests panel opened, and its table showed no row within 30 s. The kept log shows no event confirmed only by
  timeout during the test. The frontmost lines show only uniterm activating, under two process ids that alternate:
  96726 and 31876. No other app took the front. Neither process was alive after the run. The test passed alone right
  after, on the same tree.
- Suspected cause: unknown. One reading is that the open from another program reached the other uniterm process. That
  is not traced.
- Status: unresolved.

## Fixed

### `PatternTests.testACatastrophicPatternStopsAtItsLimitAndStopsUsingCPU`

Fixed by: "Stop sampling other threads' CPU after a stopped pattern match"

- Seen: 2026-11-22, in the first CI `package` run of the PR that added it.
- Evidence: the process used 0.43 s of CPU in the half second after the match stopped, against a 0.15 s bound. The
  match runs on the calling thread and ends when the search returns.
- Cause: the check read the whole process's CPU. The package suite runs in one process, and an earlier test's work
  can still be running there.
- First fix: "Check the stopped pattern match's CPU per thread". The test sampled each thread's CPU over a window
  before the search and an equal one after. It failed when one thread used half the window more than its baseline.
- Seen again: 2026-11-23, twice in CI `package` runs of the PR for the palette's Control-K and Control-A keys, on one
  head. One thread used 0.27 s and then 0.43 s over its baseline, against the 0.25 s bound. That PR touches only the
  palette's key route. A `workflow_dispatch` run on main passed the same job once.
- Cause of the second failure: `search` matches on the calling thread and returns when the match stops. The calling
  thread then sleeps through the after window. So that window could only see other threads, such as a background
  worker that an earlier test left with work.
- Fix: the test drops the CPU windows. It keeps the timed-out outcome and the bounded return, which are what it proves.
  The fix's CI run and the palette PR's run after it both passed.

### `MapViewerUITests.testCommandORoutesAGeoJSONFileToTheMapAndShowsItsPins`

Fixed by: "Answer the open panel through a file in UI tests" and "Size the real open panel's waits to its query cost"

- Seen: 2026-11-08, once, in a run of `TextViewerUITests` and `MapViewerUITests` together.
- Evidence: the shared open-panel helper at `UnitermUITestCase.swift:227` failed with "no go-to-folder sheet" after
  Cmd-Shift-G. The cg server restarted while that run was going. `MapViewerUITests` then passed 8 of 8 alone.
- Suspected cause: Cmd-Shift-G sent before the open panel took key focus, as in the pane-tree entries above.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.
- Seen again: 2026-11-20, once, in a run of `MapViewerUITests` alone with 10 tests. The go-to field check at
  `UnitermUITestCase.swift:379` failed. The field held the path of the test that ran just before,
  `testARestoredFileLoadsAndClearingItSticksOverARelaunch`, not this test's. The go-to sheet remembers its last
  path, so the paste never landed. The same class order then passed 10 of 10, and the test passed 3 of 3 alone.
- Suspected cause of this sighting: the paste's Cmd-V went nowhere, as Cmd-D did in the next test. Both fit a key
  sent while the app or the sheet did not hold key focus. Autocomplete is not the cause, since the field held a whole
  earlier path.
- Reruns: the whole `MapViewerUITests` class then ran 5 more times in its original order, with 11 tests each. Every
  run passed. Counting the rerun above, the class order passed 6 times after the failure.
- Seen again: 2026-11-22, in two full local `make ci` runs and one run of the five classes up to
  `DataViewerUITests` on main. Each failing test passed alone, and the next full run failed another open-panel test. The messages were "the panel never selected sales.csv" at
  `UnitermUITestCase.swift:392`, "no go-to-folder sheet" at line 368, and "Timed out while synthesizing event" on
  Cmd-Shift-G at line 365.
- Cause: every accessibility query of an element in the main window takes 1.5 to 5 s while the system's open panel
  shows, and 0.03 s once it is gone. The panel runs in another process, and each query snapshots its whole tree. The
  helper's 5 s waits held one or two queries. A wait whose first query came before the panel was ready timed out
  before its second returned. On 2026-11-22, the selection wait queried at 7.9 s and 13.1 s and failed, and Cmd-Shift-G
  took 5.1 s just to synthesize. `DataViewerUITests` passed 60 of 60 alone on main. It failed on the third pass when
  the five classes before it ran first.
- Fix: the app's open panel now answers through a file in UI tests, so the tests about what uniterm does with a
  chosen file never show the system's panel. `OpenPanelUITests` and
  `DataViewerUITests.testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAFile` keep the real panel for Cmd-O and the
  Open button. Their waits on the panel allow 20 s, which holds several queries at the measured cost. With the hook,
  the four viewer classes and `OpenPanelUITests` passed 98 of 98 over two passes.

### `TextViewerUITests.testAnEditedFileReloadsInPlaceAndByRename`

Fixed by: "Answer the open panel through a file in UI tests" and "Size the real open panel's waits to its query cost"

- Seen: 2026-11-15, once, in the second CI `app` run of PR #49, which does not touch the open-panel helper.
- Evidence: the shared open-panel helper at `UnitermUITestCase.swift:308` failed with "the go-to-folder sheet never
  closed". The other 157 UI tests passed. `TextViewerUITests` then passed 13 of 13 alone. The same message failed
  `DataViewerUITests.testCommandORoutesACSVFileToTheDataViewer` on PR #43's first CI run. It failed
  `DataViewerUITests.testCommandOOpensAWorkbookAndTheSheetPickerSwitchesSheets` on PR #53's first CI run, which does
  not touch the helper either. The rerun passed.
- Suspected cause: Return reached the go-to-folder sheet before it accepted the pasted path. Not confirmed.
- Seen again: 2026-11-21, in the first CI `app` run of PR #80, which does not touch the open-panel helper.
  `DataViewerUITests.testCommandORoutesACSVFileToTheDataViewer` failed at `UnitermUITestCase.swift:384` with "the
  go-to-folder sheet never closed". uniterm was frontmost, and no element in it held keyboard focus. The rerun passed
  this test.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.
- Cause and fix: as for `MapViewerUITests.testCommandORoutesAGeoJSONFileToTheMapAndShowsItsPins` above.

### `MarkdownViewTests.testATwentyMegabyteDocumentNeverStallsTheMainThread`

Fixed by: "Prove the Markdown parse stays in the page by the bytes the host serves"

- Seen: 2026-11-18, once, in the CI `package` rerun of PR #68. That PR changes only the CI cache step.
- Evidence: the longest gap between main run loop turns was 0.54 s, against the test's 0.5 s bound. The first
  `package` run of the same head passed this test. Locally the longest gap is about 25 ms.
- Cause: a runner pause, most likely. The host hands the page the whole 20 MB in one `didReceive`, and that costs well
  under the 25 ms local gap, so the handoff does not explain 540 ms. The test timed run loop turns, which a paused
  runner stretches. It could not tell that from a parse on the main thread.
- Fix: the test drives the scheme handler with a recording task and requires the exact document bytes. A host that
  served anything it had parsed or changed fails it, as a handler made to append a comment did. The gap bound stays,
  at 5 s, to catch a gross stall such as a host-side parse of the whole document.

### `TerminalSessionIntegrationTests.testProcessStartedEventReportsTheDirectChildInProgramMode`

Fixed by: "Wait for the child's exec of login before reading its name"

- Seen: 2026-11-21, once, in the first CI `package` run of PR #79, which changes no terminal code. Its shell-mode twin
  `testProcessStartedEventReportsTheDirectChild` failed once on main's CI on 2026-11-18, found later in CI's logs.
  Both read the name through the same helper.
- Evidence: `TerminalSessionIntegrationTests.swift:1064` failed with "the direct child is not login". The child's
  name read as `xctest`. The rerun passed.
- Cause: the test read the child's name with `sysctl` as soon as `processStarted` arrived. A child that has forked but
  not yet run `exec` on `login` still carries `xctest`'s name. The event was right to name that child.
- Fix: the test reads the name until it turns to `login`, within 10 s, then asserts it. A child that is not `login`
  never takes the name, so it still fails. The race did not reproduce locally, so the test pins the fix, not the
  failure. Both `processStarted` tests passed after the change.

### `ExecDriverChannelTests.testAStalledStdinFailsWithoutBlockingTheEmitter`

Fixed by: "Measure stalled emits against the same emits to a reading driver"

- Seen: 2026-11-21, once, in the first CI `package` run of PR #81, which changes no exec driver code.
- Evidence: `ExecDriverChannelTests.swift:349` failed with "emitting blocked the main thread". 40,000 emits took
  5.15 s against the test's 5 s wall-clock bound. The rerun passed this test. Locally the same emits take about 0.5 s.
- Cause: the bound timed the emits themselves, which include encoding every event. A loaded runner slows that, so
  the bound tracked the runner's speed. The transport was right: its writes run on their own thread.
- Fix: the test times 10,000 emits to a driver that reads them, then 10,000 to the stalled one, and requires the
  stalled median cost per emit, over chunks of 1,000, to stay under twice the healthy one. Both runs' 2.6 MB stay
  under the 4 MiB retained bound. So a reader that falls behind cannot get the healthy driver cut off, and the stalled
  run is measured before it fails, while emits still take the backed-up path. Unmeasured emits then pass the bound
  for the failure check. The median keeps one runner pause from counting: a 1 s sleep in each run passed. A send made
  to sleep 200 µs while more than 64 KiB waited fails it, at 344 µs per emit against 13.5 µs. The test passed 30 of 30
  with a busy loop on each of 14 cores. The new `drain` driver mode reads and discards stdin. The stall's failure is
  found among the channel ends, so the healthy channel's close cannot stand in for it.

### `ExecDriverChannelTests.testAnOversizeClipboardWriteIsRefusedAloneAndOneAtTheBoundArrives`

Fixed by: "Join a driver's stderr line that arrives in pieces, and show a lone partial line after a pause"

- Seen: 2026-11-15, once in a full `make test-package` run during the UTERM-007 M5 work-queue run.
- Evidence: it timed out waiting on the channel. It passed alone and with its class, in 8.5 s, and in the next full
  runs. It launches a real perl driver, so a loaded machine slows it.
- Seen again: 2026-11-17, once, in a local full `make test-package` run during the UTERM-015 M5 work-queue run, which
  touches the script listener and its wire, not the exec driver. It timed out after 15.5 s "waiting until the channel
  ends or answers both writes and the command after them". It passed alone in 0.13 s, with its class, and in the next
  full run.
- Seen again: 2026-11-17, in full `make test-package` run KE15J2 during the UTERM-015 M6 work-queue run. The history
  held `"got error"` and `"bad-argument"` as two entries, where the wait looks for the one line
  `"got error bad-argument"`.
- Cause: a product bug, not load. The driver writes that line in pieces, and the stderr ingress keeps each read as
  whole lines. When the reader wakes between the pieces, the line splits in two. See
  `spec/bugs/20261117-stderr-line-split-across-reads-shows-as-two-lines.md`.
- Fix: the stderr ingress joins a partial line with the next read, and lets a lone one go after 250 ms of quiet. The
  fixture driver writes each line in one piece, so the test does not depend on that period. A unit test that offers a
  line in two pieces failed before the fix with two lines. A channel test with the tail check turned off timed out.

### `TerminalSessionIntegrationTests.testAPendingClipboardAnswerIsStaleAfterAPolicyChangeOrAClose`

Fixed by: "Give terminal sessions their clipboard, so tests use a private one"

- Seen: 2026-11-15, once, in a local `make test-package` run during a work-queue run that touches no terminal code.
- Evidence: the test asserted that the system pasteboard held `SECRET-STALE`. It held text another session had just
  written to it. The test passed alone, and the next full run passed.
- Cause: the terminal surface read and wrote `NSPasteboard.general`, and so did the tests. Any other program that
  copied mid-run changed what the test saw. The product's clipboard policy was right.
- Fix: the terminal engine takes the pasteboard its sessions use, and the app passes the system's. The integration
  tests make their own with `NSPasteboard.withUniqueName()`, so they no longer save and restore the user's clipboard.
  A thread that wrote the system pasteboard every 50 ms failed the old test with "a stale write landed". The fixed
  test passed with the same thread running.

### `FindTests.testSearchingTheDecodedCapNeverBlocksTheMainThread`, now `testATextSearchNeverRunsOnTheMainActor`

Fixed by: "Prove the text search runs off the main actor with a gate, not a turn count"

- Seen: about ten times between 2026-11-14 and 2026-11-17, in CI and in local full `make test-package` runs. It counted
  3 to 82 main-actor turns where it expected more than 100. It passed alone each time.
- Evidence: the search ran off the main actor all along. `FindMatching.searchOffMain` is `@concurrent`. Earlier test
  classes that warmed Foundation's case-insensitive tables shifted the count, so the count tracked timing.
- Cause: the test counted `Task.yield()` turns while the search ran. That measured how long the search took and how
  busy the main actor was, not where the search ran. The product was right.
- Fix: the pane's text search is now a `@concurrent` function property, so nothing assigned to it can run on the main
  actor. The test assigns one that waits at a gate, and the main actor opens the gate only after it sees the search in
  flight. A coordinator made to search inline on the main actor fails it, with "the search never reached the pane's
  searcher". The test now searches a short document. Laying out four million characters could hold the main actor
  long enough that the gate gives up, and the gate proof does not need the size.

### `LaunchOpenCoordinatorTests`, the batch and refused-package tests

Fixed by: "Wait for the launch-open coordinator's drain instead of yielding a fixed number of times"

- Seen: 2026-11-14 and 2026-11-15, once each, in CI's package job on branches that do not touch the launch-open code.
- Evidence: `testABatchOpensOnePanePerFileAndSummarizesFailures` saw 0 of 2 folder panes open, and no failure
  message. `testAPackageIsRefusedThroughTheLaunchServicesPath` found no failure message for the refused bundle.
- Cause: the fixture's `settle()` yielded the main actor 50 times. The router finds each path's type off the main
  thread, so yielding never waited for it, and a slow runner asserted first. Tests that check that nothing happened,
  such as `testAFailedWarmOpenWithNoWindowOpensNoShell`, passed without proof the same way. `LaunchOpenApprovalTests`
  had the same flaw, with up to 20,000 yields. The coordinator itself was right.
- Fix: the coordinator keeps its drain task, and `idle()` waits for it to end. Both fixtures' `settle()` await it.
  `testASenderThatAlreadyExitedTouchesNothing` had used `settle()` to let its watcher's end report run, so it now awaits
  that task. A 300 ms sleep in the coordinator fixture's type lookup failed three coordinator tests with the CI symptom,
  then crashed the run with an index out of range. After the fix, the coordinator class passed with the sleep in
  place. The approval fixture has no such hook, so a denial made to open its files checked those tests instead. Three
  failed, so they do not pass by default.

### `ScriptReplTests.testRestoredHistoryIsNeverEvaluated`

Fixed by: "Wait for the REPL's line event before checking what the restored history did"

- Seen: 2026-11-15, once, in the first CI `package` run of PR #53, which does not touch the REPL.
- Evidence: `ScriptReplTests.swift:554` found `events.lines` empty where `["(+ 20 22)"]` was expected. The test
  passed 20 of 20 alone, and the rerun passed.
- Cause: the test read `events.lines` as soon as `42` showed on the pty. The `.line` event comes over the host's
  socket, a separate path, so it can arrive after the output. The REPL itself was right.
- Fix: the test waits until the socket reports the typed line and the end of its evaluation. The socket keeps its
  order, so a restored line that ran would be reported before that. Delaying every event in the test's recorder by
  300 ms failed the old test with the CI message, and the fixed test passed with the same delay.

### `ExecPaneTests.testAStalledDriverNeverHoldsTheMainThread`

Fixed by: "Measure the stalled-driver flood against the same clicks with no driver"

- Seen: 2026-11-15, twice, in both CI `package` runs of PR #49, at 5.47 s and 8.62 s against a 5 s bound.
- Evidence: locally the 20,000 clicks took 1.61 s with no driver and 1.72 s with the stalled one. The main thread's
  turn came 11 ms after the flood.
- Cause: the bound timed the clicks themselves, which AppKit makes cost about 80 µs each. A CI runner is several times
  slower. The driver was right.
- Fix: the test times the same clicks with no driver first, and the flood must cost less than twice that. A send made
  to sleep 200 µs fails it, at 9.8 s against 3.2 s.

### `FileWatcherTests.testChangesToOtherFilesInTheFolderDeliverNothing`

Fixed by: "Assert that a folder watch notes no neighbor's change, not one note per write"

- Seen: 2026-11-14, four times in CI's package job, in the text viewer PR and the Janet scripting PR.
- Evidence: `FileWatcherTests.swift:112` counted 2 notes where it expects 1. The test passed 10 of 10 alone.
- Cause: the test expected exactly one note for the file's own write, and a write can make two. A folder event from the
  neighbor churn can be handled after the write, so it sees the file changed. The in-place write can also raise two file
  events. The coalescer merges them, so the viewer still reloads once. The watcher itself was right.
- Fix: the test drains the watcher's queue after the churn and asserts that the churn made no note. Then it asserts the
  write made at least one. A watcher made to note every folder event fails it, with 3 churn notes. After the fix, the
  file watching tests passed 30 of 30 alone.

### `BrowserRecoveryTests.testKillingTheSelectedTabShowsTheMessageAndReloadBringsBackItsHistory`

Fixed by: "Wait for the reloaded title in the browser recovery test"

- Seen: 2026-11-07.
- Evidence: it failed once in a full `make test-package` run. Run alone, it failed 1 of 3 times. The failure read
  "127.0.0.1" where "B" was expected. A later series of 12 isolated runs did not reproduce it, so the rate there is 0 of
  12 before the fix and 0 of 7 after.
- Cause: the test waited for the reloaded page to finish loading, then read the tab title once. Reload builds a new web
  view with no title. WebKit reports the page title a moment after the load ends. Until then the tab shows the host,
  which is `127.0.0.1` on the fixture server. The product is right to show the host while the title is unknown. The
  race is in the test, which had no signal that the title had arrived.
- Fix: the wait that follows Reload now includes the title, so the assertion runs after the title has arrived.

### `WindowsUITests.testCommandWClosesOnlyTheKeyWindow`

Fixed by: "Wait for the app to be frontmost before UI tests type, and paste open-panel paths"

- Evidence: alone, it failed 1 of 6 at the foreground assertion after Cmd-W. The app state read `runningBackground`.
- Evidence: in a full suite, it failed because `echo "K:$((6*7)):"` never produced output in 20 s after a click on the
  first window.
- Cause: the state read right after a window close can lag. The test read it once. Keys sent while the app was still in
  the background went nowhere. The product has no code that hides or deactivates the app.
- Fix: the foreground assertion now waits for the state to settle, without activating the app. The same wait replaces
  the one-shot read in `testClosingTheLastWindowKeepsTheAppRunningAndCommandNOpensAgain`. `waitForTerminal` activates
  the app before the first key.

