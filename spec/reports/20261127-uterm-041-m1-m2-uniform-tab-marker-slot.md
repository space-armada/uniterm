# UTERM-041 M1-M2: a uniform marker slot for every tab

This report covers a `/work-queue` run of `next 1` on 2026-11-27, on branch `agent/petunia`. The run took one row,
UTERM-041 M1-M2, from `spec/proposals/UTERM-041-uniform-tab-marker-slot.md`.

## Run state

- `make ci-waiting-evidence` reported every CI-waiting row as WAITING. UTERM-060 and UTERM-045 were held with
  `--hold`.
- Before the first milestone, the branch was rebased onto `upstream/main`. The tip upstream was "Merge pull request
  #131 from ripta/agent/petunia-land7/uterm-067". 30 commits that had already landed dropped out. One redundant snip
  was dropped after the rebase, and the tree matched.
- Base commit for the run and the row: "Record the suspend and resume row's review and the pause after it".
- The specs live in the code repo, so the code commits are the specs commits.

| Row | Milestone | Run status | Note |
|---|---|---|---|
| UTERM-041 M1-M2 | UTERM-041 M1 | DONE | UI tests ran after M2; see "UI runs" |
| UTERM-041 M1-M2 | UTERM-041 M2 | DONE | Paused here at the user's request, before the row review |
| UTERM-060 M5 | | HELD | WAITING on CI: no Cmd-T stall failure seen yet |
| UTERM-060 M7 | | HELD | WAITING on CI: no app job reached its time limit. Also waits on M5 |
| UTERM-045 M4 | | HELD | WAITING on CI: about 3 of 33 clean launcher scroll runs |

## Best guesses from the plan

1. One shared authority predicate. It is extracted from the command path, with no change in behavior, before
   anything builds on it. The command path and the marker both call it. This rests on "Access mode or live
   controller" and on the risk "The marker misstates what a grant reaches". If the guess is wrong, the cost is a
   second copy of the check.
2. Pane-level order. The markers sit directly leading the control badge, and the asking badge sits leading of them.
   With no badge, the markers take the badge's corner. This rests on decision 3's "just to the leading side of the
   pane's control badge". The proposal never places the asking badge.
3. Overflow cue. Edge fades show that more tabs lie past an edge. The bar has no scroller and no chevron. This rests on
   "Markers outside the tab bar", which says there is no scroll control.
4. Marker identifiers. Tab markers are `tab-<index>-marker-<kind>`, and pane markers are
   `pane-marker-<kind>-<paneID>`. This follows the existing `tab-N` and `pane-asking-<id>` scheme.
5. Applet call shape. One call carries a value type. In M1 it holds the owner set. In M2 it gains the controlling
   tabs. This rests on "How the host hands the chip down".
6. A session root's tab is kept in WindowKit, not ScriptHost. ScriptHost does not depend on AppletKit.
7. Corrections of fact to the proposal:
   - The terminal tab bar bug is fixed, and `trailingReserve` exists.
   - Several line citations are stale.
   - No user action dissolves a group.
   - The badge shows once a driver run has started.
   - `appletTabsDidChange` also records the focused tab.
8. M1 stays one milestone, so the milestone numbers that other proposals cite do not change.

## Checks left to the user

- Hearing the markers and the chip's names with VoiceOver. The run proves the accessibility tree.
- Confirming that `gearshape.2.fill`, `arcade.stick`, and `cpu` resolve on macOS 26.0. This machine runs a later macOS.

## UTERM-041 M1

### What was built

- The command path's authority check was extracted first, with no change in behavior. `isMember`,
  `connectionMayAddress`, `driverStanding`, `driverMemberRefusal`, and `driverMayAddress` now live in
  `MainWindowController+Control.swift`. The scripting and exec command paths call them, and so does the marker.
- AppletKit has a marker kind table (`AppletMarker.swift`) with `authority` and `runEnded`, and a `PaneAuthority` value.
  It also has `AppletTab.markers`, the one bar predicate `AppletTabList.barShows(forTabCount:)`, and two new `Applet`
  calls: `authorityDidChange(_:)` and `performMarkerAction(_:kind:on:)`.
- The shared tab bar takes published tabs. It draws each marker as its own image element. It scrolls by trackpad and
  shift-scroll, shows edge fades, keeps the selected tab in view, and hides below two tabs.
- Terminal, browser, and questions use the predicate. The browser republishes on every `tabOwners` change. The text,
  image, map, and data viewers mark their one tab through the shared helper.
- `PaneFrameView` draws pane-level markers directly leading the badge, or in the badge's corner when no badge shows.
- A debug-only fixture applet, `fixture-marked`, publishes a run-end marker for the UI captures.

### Bugs

- Fixed by this commit: `bugs/20261121-tab-bar-overflow-hides-tabs.md` and
  `bugs/20261122-questions-bar-disagrees-with-the-shared-hide-rule.md`. Both are marked fixed, and so is the index.
- No new bugs found.

### Implementer best guesses

- The host's "takes commands or content" test is `AppletCommandHandling`, or `SourceReplacing` and not `InputOwning`.
  A driver counts only through `AppletCommandHandling`. This rests on the M1 check wording and `sendTarget`.
- A marker view is 20x16 points, since the filled gears are 19x15 at 12 points. Pane-level markers use a 20x20 slot,
  like the badge.
- At the 80-point narrowest tab, two markers stay whole and the title gives up all its width.
- A shift-held vertical wheel is converted to a sideways scroll by an `NSScrollView` subclass.
- The run-end capture uses the existing debug-only fixture registry (`UNITERM_TEST_APPLETS=1`), not a new hook in the
  app.
- The driver's ended-run parity case is proved through `driverStanding`, since no command can be sent on a closed
  channel.
- The data viewer uses the helper, though no control mode reaches it.

### Checks

- `make fmt`, `make lint`, `make check` (includes `check-ui-wheel.sh`), and `make build` all passed.
- `caffeinate -dimsu make test-package` passed on the final tree (exit 0).
- An unowned failure appeared in the first round: `ProcessReaperTests.testTheReaperLogsThePidPathAndFailuresButNotAGoneHelper`
  had 3 OSLog assertions get `[]`. It passed in the second round's full run. The commit "Name log quarantine as the
  cause of the reaper log test's failures" already attributes it to log quarantine. It was not rerun on the base
  commit.
- The UI test target build (`xcodebuild build-for-testing`) succeeded.
- `proposals.py check` printed `[]`. `freeze` shows no hunk on UTERM-041.
- UI runs: `make test-app-select UI_TESTS='MarkerUITests QuestionsUITests'` ran 3 times, at 19:07, 19:08, and 19:19.
  Each failed before any test with "Timed out while enabling automation mode". The UI tests have not run yet. The
  next attempt follows M2. The full suite runs at the row review.
- Test cost: there is no `test-cost` target. The new package tests each take under 0.6 s. `AppletTabBarTests` runs
  16 tests in about 0.11 s. `PaneAuthorityTests` takes about 0.9 s.

### Review

ADR impact: no conflict, deviation, or supersession. ADR-14 P7 and P11, ADR-17, ADR-08, ADR-05, and ADR-02 are
consistent. No uncovered decision passes the ADR bar.

Reviewer findings, all fixed:
1. The driver's per-command check kept its own inline copy of the check. It now calls the shared steps, and a parity
   test covers five states.
2. The "connection acting from the pane" branch had no test. A real-host test now covers it in `ControllerBadgeTests`.
3. Two checks had no test: the badge clearance with the new-tab button hidden, and a run-end click calling nothing at
   both positions. Both now have tests, and `performMarkerAction` is exercised.
4. The plan's run-end UI capture had been skipped. It is now built through the fixture registry.
5. The overflow test had been written after the fix. It was run against a copy of the old bar and failed as the bug
   says.
6. Proposal lines ran over the width. They are rewrapped.

### ADR candidates

The implementer named two: "an authority sign comes from the check that enforces it", and "a kind table owns every
marker's look and meaning". Both were already declined in the proposal's Decision Log on 2026-11-21. ADR-14 P7 and P11
cover the first. The second is local to this proposal. Neither is recorded again.

## UTERM-041 M2

### What was built

- The chip kind (`cpu`, inert, no actions) sits between `authority` and `runEnded` in the kind table. A chip carries
  the host-supplied controller names, which it shows in its tooltip and accessibility value.
- `PaneAuthority` carries the owner set, the controlling tabs with their names, and the driver names, in one value.
- The window records each session root's tab, keyed by root and pane. The entry is set before the host hears of the
  session and cleared before the host hears it ended. A pane close drops that pane's entries.
- `ScriptHost.controllerSessionRoot(_:)` is a non-mutating query that asks `authorize`'s questions and changes
  nothing.
- The terminal and the REPL publish the chip. A driver's chip shows at the pane level, also beside a tab bar.
- Both pane-close paths now refresh control marks, so a dissolved group clears the chip on that turn.

### Implementer best guesses

- The window keeps the root-to-tab record, since ScriptHost cannot name `AppletTabID`. AppDelegate still drops the
  tab. This rests on the package dependency rule and the proposal's risk text.
- The query also checks ancestry. So a lapse drops the chip at the next refresh, which is at the latest the next call.
  The binding itself is dropped only by that call, as the check says.
- "Owns a group" counts groups in the controller's own window.
- The chip's names come from `controllerName(owner)`, the badge's own names.

### Checks

- `make fmt`, `make lint`, `make check`, `make build`, and the UI target build all passed.
- `caffeinate -dimsu make test-package`: 3478 tests. The only failures were the known log-quarantine signature, in
  `ProcessReaperTests.testTheReaperLogsThePidPathAndFailuresButNotAGoneHelper` (3 assertions). In one run during a
  concurrent UI run, `BrowserHungProcessTests.testAKillLogsThePidPathAndFailuresButNotAGoneProcess` also failed with
  the same "log entry missing" signature, and it passed on rerun. Neither was rerun on the base commit.
- `proposals.py check` shows only the end-of-row findings: implemented status and the queue row move.
- Test cost: the full package suite took about 320 s. Each new test runs in under 1 s.

### Review

ADR impact: no conflict, deviation, or supersession. ADR-14 (P1, P2, P7, P8, P11, P12, P14, P15), ADR-02, ADR-03,
ADR-12, ADR-15, ADR-16, and ADR-17 are consistent. The window-side join is explicit, so the CLAUDE.md rule on implicit
state flow does not apply. No uncovered decision passes the ADR bar.

Reviewer findings, all fixed:
1. The ancestry-lapse check was not proven end to end. A real-host window test now shows the chip gone by the end of
   the next call.
2. A driven pane with both markers was not proven, and neither was the reach covering both. A fake-applet test now
   asserts the order and the reach, and a real map viewer test asserts the order.
3. The chip on the bind's own turn was not proven. A test now hooks the bind's report and sees the chip inside it.
4. A vacuous ExecLayoutTests assertion is replaced by one that checks the group is gone.
5. `sessionTabs` could leak an entry when an applet never reports a session's end. A pane close now drops that pane's
   entries, with a test that fails without the filter.
6. Two proposal sentences said the host knows the tab. They are amended in place, with the old text quoted in the
   Decision Log.

## UI runs

- 19:07, 19:08, 19:19, and 19:21: `make test-app-select UI_TESTS='MarkerUITests QuestionsUITests'` timed out entering
  Automation Mode each time. No test ran.
- 19:47 (MarkerUITests and QuestionsUITests): 7 failures.
  - Three held-controller tests failed because the script ran in the background of a shell that exited. It lost its
    ancestry, and the host refused it as "not running in a uniterm pane".
  - The overflow test reselected the tab already selected.
  - `testARunEndMarkerShowsInATabBar` failed because a stray hardware key closed the fixture's tab while another app
    held focus. The fixture now takes first responder. This is a mitigation, not a proven fix.
  - `QuestionsUITests.testARequesterEndingClosesItsTab` still looked for `tab-0` with one form.
  - `QuestionsUITests.testAnErrorShowsOnLeavingTheFieldAndClearsAtOnce` failed. Chrome took the front during a 5.4 s
    click, per the frontmost log. No cause in this work was found, and it was not run on the base commit. It passed on
    the next run.
- 20:09: QuestionsUITests passed 24 of 24. Three MarkerUITests still failed. The controller was refused, then two
  tests turned out to have their pane IDs swapped.
- 20:17: MarkerUITests passed 6 of 6.
- The coordinator viewed every capture:
  - the browser gears on the two controller-opened tabs and none on the user's tab, with the badge clear
  - the chip on the second terminal tab only
  - the text viewer's gears just to the leading side of the badge
  - the overflowed bar's fades, with the selected tab in view
  - the slashed gears in a tab bar and in the badge's corner
  - the one-form questions pane with no bar and no blank strip
- The full `make test-app` is still to run, at the row review.

## Found during the run, for the row review

- Reselecting the already-selected tab from the keyboard, after the user scrolled it out of view, does not bring it
  back. `BrowserApplet.selectTab(at:)` returns early when the index is unchanged, and the bar reveals only on a
  selection or count change. M1's check says the selected tab is fully in view after the user selects it from the
  keyboard. The row review fixes it.
