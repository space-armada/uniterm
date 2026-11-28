# UTERM-043 M1: suspend and resume controllers

Started 2026-11-27, as the first row of the day's third `/work-queue` run. This report also carries the run's state.
Every commit is in this repo, on `agent/petunia`.

## Why this run

The second run took `next 6`. Two of its slots went to rows that only CI can finish, UTERM-060 M5 and UTERM-045 M4.
`make ci-waiting-evidence` still says WAITING for both. The project's rule "Queue Rows That Wait on CI" says such a row
takes no slot. So this run does the next two rows in their place.

## Run state

The run's base is "8< --- snip ---", the head after the branch was rebased onto `upstream/main` at "Merge pull request
#127". Two redundant snips were dropped after the rebase.

| Row | Milestone | Run status | Note |
|-----|-----------|------------|------|
| UTERM-043 M1 | Suspend and resume | DONE | Row reviewed |
| UTERM-041 M1 | Tabs carry markers | QUEUED | |
| UTERM-041 M2 | The controller chip | QUEUED | |

The model decided to pause after UTERM-043 M1 in order to compact and reinitialize state. UTERM-041 M1-M2 is not started.
The final review and the full `make test-app` have not run.

Held, and taking no slot: UTERM-060 M5, UTERM-060 M7, and UTERM-045 M4. Each waits on CI.

Row reports:

- [UTERM-041 M1-M2](20261127-uterm-041-m1-m2-uniform-tab-marker-slot.md)

## Before the rows

### Rebase

`make fmt-check lint check test-ci` passed on the rebased tree. So did the full `caffeinate -dimsu make test-package`:
3377 tests, 10 skipped, 0 failures, in 292 seconds.

### Fixes to the proposal sweep

The second run ended with a sweep that brought 17 live proposals in line with UTERM-063. A review of that sweep, run
after it was committed, found errors. They are fixed first, in "Retire :directory from list-panes in UTERM-050 and fix
the sweep's other slips" and "Name one trust store in ADR-18's context".

- **UTERM-050:** the sweep kept `:directory` with a check, which the proposal's own rationale rejects. `list-panes` now
  reports the held path under a new key, and `:directory` leaves the reply. The user's choice of 2026-11-23, to report
  the path as held, stands. The new-key mechanism is a run best guess, and its `Decided by` line says so.
- **UTERM-019 and UTERM-054:** an older app keeps and counts an approval it cannot read, and every other approval keeps
  working. The text said it granted nothing. `browser/events` takes no version argument. A changed event takes a new
  name.
- **UTERM-056:** an invented line about what the declaration waits on is gone. The floor is stated once.
- **UTERM-020, UTERM-026, UTERM-034, UTERM-047, UTERM-049:** missed lines and missing amendment markers.
- Lines over 120 columns that the sweep added are rewrapped.
- **ADR-18:** its Context names one trust store.

`proposals.py check` prints `[]` after the fixes.

## UTERM-043 M1

### Plan

Nothing of suspend and resume exists before this milestone. The approved plan builds it in this order: process state,
group signalling, the REPL, exec drivers, commands, displays, tests.

Best guesses made at planning:

- A REPL's Suspend shows wherever its badge already lists the helper.
- The palette gets pane-scoped Suspend and Resume, plus app-wide Suspend All and Resume All.
- Neither wire changes. A change that turns up lands in place at version 0.
- The Controllers & Permissions window gets nothing for suspension.

### What was done

One implementer built the milestone. A reviewer and an ADR check read it. The commits:

- "File the bug that closing a terminal whose shell is stopped may hang the app"
- "Suspend and resume a controller without ending it"
- "Move the suspend and resume row to history"

What the build found:

- **The REPL helper does not lead its process group in the app.** libghostty starts it under a `login` wrapper, which
  leads the group and stays the parent. The first build signalled the helper's own pid as a group, and its guard
  refused. Ctrl-Z in the real app did nothing. Every package test passed, because the tests made the helper a leader
  by hand. A UI test that sends the real Ctrl-Z caught it. The log line was "not signalling helper 22114: it leads no
  group of its own". The group signal now names the wrapper as leader, by pid and start time, and requires the helper
  to be a member. The REPL tests now start the helper under a wrapper, as the app does.
- **Closing a session whose group is stopped blocks.** A package test that did this hung and was removed. The REPL and
  exec drivers continue their group before they close. A plain terminal does not. That is filed as
  `spec/bugs/20261127-closing-a-terminal-whose-shell-is-stopped-may-hang-the-app.md`, not confirmed in the app.
- **A stop or continue notice does not say which it was.** Each notice starts a read of the process state, repeated
  until two readings agree.

Best guesses made while building, each in the proposal's Decision Log as a run best guess:

- The status bar's minimum message width went from 64 to 56 points. A fourth icon slot needed 202 points against the
  200-point window minimum. A minimum that follows the slot count would be the fuller fix.
- M1's UI check said the controller "opens no pane and no tab until it is resumed". A driver cannot make a first layout
  in the real app yet. See `spec/bugs/20261127-exec-driver-cannot-name-its-pane-for-a-first-layout.md`. The check now
  says the controller's second call does not land until it is resumed.
- The rationale under "What uniterm sends a suspended controller" said today's drivers cannot parse a new exec-wire
  message. Under UTERM-063 a new message lands in place and an older driver is refused. The reason is corrected. The
  user's decision, no change, is untouched. The reviewer wanted the user asked. The run did not ask, since the user
  said on 2026-11-27 to bring out-of-date text in line with UTERM-063 without asking.
- Palette titles are "Suspend Controller", "Resume Controller", "Suspend All Controllers", and "Resume All
  Controllers". Suspend All skips a controller that is already stopped, so Resume All never takes over an outside stop.

Review findings and what happened to each:

| Finding | Outcome |
|---------|---------|
| A close can hang when the stop is not in uniterm's record | Fixed. Every close, end, and quit continues the group first |
| The REPL half of "nothing stays stopped once the app is gone" had no proof | A test now pins the OS rule, with `script` standing in for the app |
| Mouse and focus reports could reach a suspended helper's pty | Fixed. Scrolling in the alternate screen can still write cursor keys, which the REPL does not use |
| Suspend was offered for a driver that had not connected | Fixed |
| Resume then Ctrl-Z within 50 ms resumed twice | Fixed |
| The suspended strip could cut off the sentence about page code | Fixed. The strip wraps and grows |
| The As built block listed 40 test names | Shortened |
| Two kqueue watchers on a REPL helper's connection | Left. Harmless |

ADR check: no conflict. It raised one plausible tension with ADR-05 P2, "it never stops or signals the applet's work
itself". Advisory: a controller is a process uniterm spawned and already signals on close, and the REPL applet does
its own stopping. No ADR is proposed.

### Checks

- `make fmt-check lint check`: passed.
- `caffeinate -dimsu make test-package`, run by the coordinator on the final tree: 3419 tests, 10 skipped, 0
  failures.
- UI classes `ReplUITests`, `ExecPaneUITests`, `PaneControlUITests`, `StatusBarUITests`, `CommandPaletteUITests`, and
  `ScriptRunUITests`, on the final tree: 32 tests, 0 failures.
- An earlier UI run had 5 failures while Chrome, Mattermost, WezTerm, and Finder came to the front. Each passed when
  rerun alone.
- The implementer saw `TerminalSessionIntegrationTests` fail in three full runs before its last change. Its new test
  runs a real engine in the test process, and the engine sets environment variables. The test now restores the
  environment. The coordinator's full run after that passed.
- The coordinator viewed two captures: the suspended driver strip with the "1 suspended" slot, and the suspended REPL
  strip.
- One aborted test left a stopped `login` process behind. The coordinator ended it.

Left to a person: how the badge menu and the slot's menu look.

### Row review

A second reviewer read the row's commits, with the changes made after the first review. It found no serious problem.
Its fixes are in "Offer Resume for an outside stop that follows a quick suspend and resume":

- A suspend and a resume sent before the stop was seen left a later outside stop with no Resume. The test for it
  failed before the fix, with "Resume was not offered for a stop from outside".
- A resumed pane reported focus even when focus had not changed.
- A comment said the REPL helper leads its own session. It does not.
- `ReplProcessTreeTests` restores only `GHOSTTY_RESOURCES_DIR`, the one variable the engine sets.

Bugs filed from the row:

- `spec/bugs/20261127-closing-a-terminal-whose-shell-is-stopped-may-hang-the-app.md`, not confirmed in the app.
- `spec/bugs/20261127-terminal-engine-changes-the-apps-own-environment.md`.

Checks after the row review's fixes:

- `make fmt-check lint check`: passed.
- `caffeinate -dimsu make test-package`: 3420 tests, 10 skipped, 3 failures. All 3 are
  `ProcessReaperTests.testTheReaperLogsThePidPathAndFailuresButNotAGoneHelper`, which passes alone. `log show` for the
  run has the `xctest` process's line "QUARANTINED DUE TO HIGH LOGGING VOLUME" at 18:15:46, before that test ran. The
  cause is now recorded in `spec/bugs/20261127-reaper-log-test-reads-no-entries-in-some-full-runs.md`. The implementer's
  full run had the same 3 failures. The run before these fixes passed. Suspend and resume adds tests and log lines, so
  it may make the quarantine more likely. That is not measured.
- `make test-package-select` with `TerminalSessionIntegrationTests` ended the process with no result in
  `testShellSeesTheScrubbedEnvironmentAndUnitermsIdentity`. That is the open bug
  `spec/bugs/20261127-terminal-test-exits-silently-under-make-select.md`. The test passed in the full run.
- `ReplUITests` and `ExecPaneUITests`: passed.

The user was not asked about the changed UI check. It is listed under "Best guesses" above for the user to see.
