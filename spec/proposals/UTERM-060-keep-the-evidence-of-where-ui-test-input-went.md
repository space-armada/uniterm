# UTERM-060: Keep the Evidence of Where a UI Test's Input Went

**Status:** accepted
**Created:** 2026-11-25
**Updated:** 2026-11-27

## Impacts

- UTERM-044 — its per-shard upload ("Each failing shard uploads its results under its own name") must carry each
  shard's kept log, from "Where the log is taken". Its shard target runs through the same `scripts/run-ui-tests.sh`.
- UTERM-045 — "Which call sites move" left keys out. "Whether clicks need settling" waits on a click flake with
  evidence about the click. The kept confirmation log is evidence for both. Neither decision changes here.

## Summary

XCTest's `testmanagerd` already logs, for every synthesized event, whether the app confirmed processing it. A failed UI
run keeps that log, and each failing test carries a timeline of which app was frontmost while it ran. A failure then
says which of its events uniterm never confirmed, and whether another app was in front at the time. A debug build of
uniterm then also records the input it receives, so a failure says whether an unconfirmed event ever reached uniterm.

## Motivation

Four open entries in `spec/flaky-tests.md` share one pattern. A single synthesized event takes 5 or 20 s to send, and
its effect never comes:

- `ShortcutOwnershipUITests.testARemapOntoAnAppletKeyWinsAndWarnsOnce`: Escape took 5.09 s to synthesize, and the
  palette never closed. The palette check answered every 0.57 s for the next 11 s, so the app was not hung.
- `CommandPaletteUITests.testAProgramTitleShowsNeutralizedAsATab`: Cmd-K took 20 s, and the palette never showed.
- `StatusBarUITests.testClickingTheDismissControlClearsAnError`: a click took until 8.20 s, and the message stayed.
- `WindowsUITests.testCommandNOpensASecondWindowWithItsOwnShell`: Cmd-N took 20 s, and no second window opened.

XCTest sends a key as numbered events: Command down, the key down, the key up, Command up. After each one,
`testmanagerd` waits up to 5 s for an accessibility notification from the target app saying it processed that event.
It logs the outcome of each:

```text
Event 809: Key 55 down - waiting for confirmation...
Event 809: confirmed by AX Notification
Event 810: Key 17 down - waiting for confirmation...
Event 810: confirmed implicitly by confirmation delay timeout of 5.00s
```

The stall lengths are multiples of that 5 s window: one unconfirmed event for Escape and the click, four for Cmd-K and
Cmd-N. A local run on 2026-11-25 reproduced the shortcut test's failure at Cmd-T: Command down and Command up were
confirmed within milliseconds, and the T down and T up each waited out the 5 s. The palette never opened. During those
10 s, uniterm's process sent `testmanagerd` other event notifications about every 8 ms, so its event loop was running.

CI keeps none of this. UI runs set `-collect-test-diagnostics never` (`Makefile:48`), and the runner's system log goes
with the runner. So every sighting ends "not confirmed", and no fix can be chosen.

The confirmation log separates an event uniterm confirmed from one it did not. It cannot say why an event went
unconfirmed. Another app in front at that moment is one cause the test runner can see for itself, through the system's
app activation notifications. What uniterm did with an event it confirmed is a question only uniterm can answer, and
none of the four sightings has reached it yet.

## Design Decisions (Settled)

### Keep testmanagerd's event confirmations for a failed run

Decision: when a UI run fails, its `testmanagerd` log for the run is kept, in CI and in local runs. A CI runner's copy
goes up with the uploaded test results.

Rationale: the log is XCTest's own receipt for each event, written by the same daemon that times the stall. It covers
every synthesized key, click, and scroll in every test, with no product code. A CI runner is gone when the job ends, so
the log must be taken inside the job.

### Record which app was frontmost

Decision: the UI test base class records which app was frontmost while each test ran, and a failing test carries that
record.

Rationale: an unconfirmed event may have gone to another app. The test runner sees activation changes itself, so this
needs no product code.

### Record inside the app, after the kept log

Decision: a debug build records the input uniterm receives, when a UI test asks it to. It is built after the kept log
and the frontmost record, and checked first against the local reproduction. A release build compiles none of it.
Amended 2026-11-25; see Decision Log.

Rationale: the kept log and the frontmost record settle whether uniterm confirmed an event and whether another app
had the keys. They need no product code, so they come first. An in-app record answers what they leave. For an event
left unconfirmed while uniterm was in front, a record of it says it arrived and posted no confirmation, and no record
says it never arrived. For a confirmed event, it says what uniterm did with it. The local Cmd-T failure is the first
case, and it reproduces in about 3 of 9 runs, so the record can be checked now rather than on a later CI sighting.

### Evidence, not a fix

Decision: nothing here changes a wait, sends an event, or retries anything. No test waits on the kept log, the
frontmost record, or the in-app record. They are read after a failure.

Rationale: the flaky-test rule forbids retries, longer timeouts, and weaker assertions. UTERM-045 settled that a
settle never waits on the outcome of the event it comes before.

### Where the log is taken

Original question and candidates:

- **The UI run script, after a failed run.** `scripts/run-ui-tests.sh` wraps every UI run, local and CI, and already
  acts on a failed exit. It notes the run's start time, and after a failure runs `log show` from then on for
  `testmanagerd`. It writes the result beside the run's test results. CI's upload step gains its path. The log covers
  the whole run, so a reader finds the failing test's events by time.
- **The base class, at a failing test's teardown.** It runs `log show` for that test's time window and attaches the
  result to the test. The UI test runner is sandboxed (`com.apple.security.app-sandbox` in its signed entitlements),
  and a sandboxed process cannot read the system log, so this needs a helper outside the sandbox that the runner asks.
  An addition: a new component and a new trust boundary. A test the execution-time allowance ends never reaches
  teardown, so it carries nothing.
- **A CI step on failure.** The workflow runs `log show` after a failed `app` job and uploads it. Local runs keep
  nothing.
- **The script streams the log for the whole run.** It runs `log stream` beside the tests and keeps the output only on
  failure. That catches lines below the default level, which a later `log show` misses. A stream can drop messages in
  a burst, and the event lines are at the default level, which the system keeps.
- **Turn Xcode's failure diagnostics back on.** `-collect-test-diagnostics on-failure` puts Xcode's own logs in the
  result bundle. UI runs turned it off because those diagnostics attached screen recordings that could hold the
  user's whole display (`spec/reports/20261110-uterm-004-m1-m6-control-and-trust.md:599-604`). Turning it on undoes that.

Decision: the UI run script, after a failed run. Converged in 1 pass.

Rationale: one place covers local and CI runs. The script runs after `xcodebuild` exits, so it also covers a test the
execution-time allowance ended, which no in-test path reaches. It needs no new component and no change to the runner's
sandbox. The event lines are at the default level, which `log show` finds after the fact, so a stream adds a child
process for no line the log keeps. Turning diagnostics back on brings back the screen recordings that UI runs removed.

### What the kept log holds

Original question and candidates:

- **Every testmanagerd line for the window, plus the runner's frontmost lines.** Nothing filtered out, and the
  frontmost record from "How the frontmost record is taken" on the same clock.
- **Every testmanagerd line for the window.** Nothing filtered out. A local run of one test wrote about 2,800 lines
  in 20 s, most of them event notifications that carry no source.
- **Only the event and gesture lines.** The lines that name a synthesized gesture, each numbered event, and its
  outcome. Leaves undone: it drops the sourceless notifications, which are the only evidence that uniterm's event loop
  kept running through a stall. It also matches Apple's unstated wording, so a new outcome wording is lost silently.
- **The event and gesture lines, plus uniterm's own window and front-process lines.** As above, plus the AppKit lines
  from uniterm's process. Leaves undone: the same loss of liveness evidence. Whether those AppKit lines are kept at the
  default level is not known.

Decision: every `testmanagerd` line for the window, plus the runner's frontmost lines. Converged in 1 pass.

Rationale: the Motivation's own Cmd-T analysis used the sourceless notifications to show that uniterm's event loop
ran. A filter loses them, and once a CI runner is gone they are gone for that failure. A filter also matches text
Apple does not promise, so a new wording would drop lines with no sign. Unfiltered, the frontmost lines and the event
lines read on one clock.

### How the frontmost record is taken

Original question and candidates:

- **Activation notifications, logged and attached.** The base class records the frontmost app when a test starts, then
  observes the shared workspace's app activation until the test ends. It writes each change to the unified log at the
  default level through `Logger`, and a failing test also attaches the record.
- **Activation notifications, attached.** As above, but the record lives only in the test's attachment. Leaves undone:
  a test the execution-time allowance ends never reaches teardown, so it carries nothing.
- **A poll.** The base class reads the frontmost app on a timer. Leaves undone: a change between two reads is missed.
- **Lines from the system log.** The kept log adds the front-process lines from the window server's clients. No test
  code changes. Whether those lines name every activation is not known, so a reader cannot trust a gap in them.

Decision: activation notifications, logged and attached. Converged in 1 pass.

Rationale: notifications see every change a poll can miss. Writing each change to the unified log puts it in the kept
log on the event lines' clock, so a test the allowance ended still leaves its record. The sandboxed runner already
reads the shared workspace in `focusReport` (`UITests/UnitermUITestCase.swift:324`), so this needs no new access.

### How a reader ties a failing test to its events

Original question and candidates:

- **The runner marks each test and each issue in the log.** The base class writes the test's name to the unified log
  at its start and end, and writes each issue it records with the test's name, through the same `Logger` as the
  frontmost lines. The kept log then brackets each test by name, and marks where its failing assertion fired, on the
  event lines' clock.
- **The runner marks each test in the log.** As above, without the issue marks. Leaves undone: the bracket spans the
  whole test, up to the 120 s allowance, so a reader still hunts for the failing step inside it.
- **No change.** The uploaded `.xcresult` already holds each test's and each activity's start time. Leaves undone: a
  reader aligns two artifacts in two time formats, UTC and local, every time, through `xcresulttool`, whose output
  Apple does not promise.
- **Times.** The failure carries the test's start and end wall-clock times. Leaves undone: it duplicates what the
  `.xcresult` holds, and a test the allowance ended never writes its end time.
- **The gesture names.** `testmanagerd` names each gesture as the test's step does, such as `Type 't' key with
  modifiers '⌘' (0x10)`. Leaves undone: it narrows a window but cannot find one, and it assumes Apple keeps the two
  wordings in step.
- **A report that does the matching.** A script lists, for each failing test, its gestures and each event's outcome.
  An addition: a parser of two formats Apple does not promise, against "What the kept log holds", which rejected a
  filter for that reason.

Decision: the runner marks each test and each issue in the log. Converged in 1 pass.

Rationale: the kept log then reads on its own, on one clock, and shows which events came just before the failure. A
test the allowance ended keeps its start mark, and the next test's start closes its bracket. It reuses the `Logger`
the frontmost record already writes, and adds no component. `ExecPaneUITests` already overrides `record(_:)` and calls
super (`UITests/ExecPaneUITests.swift:210-213`), so the base class's override reaches every test.

### Where the app records an event

Original question and candidates:

- **A listen-only event tap on uniterm's process, plus a `nextEvent` override.** `CGEvent.tapCreateForPid` sees each
  event where the window server hands it to uniterm, before AppKit queues it. An `NSApplication`
  `nextEvent(matching:until:inMode:dequeue:)` override records each event AppKit takes off its queue with `dequeue`
  true, including those a control's tracking loop pulls. Together they tell an event never delivered from one
  delivered and never dequeued, and from one dequeued.
- **A `nextEvent` override alone.** Leaves undone: an event that arrived and was never dequeued, as in a nested loop
  whose mask skips it or a discard, has no record and reads as never arrived.
- **A `sendEvent` override.** Leaves undone: events a nested tracking loop pulls, such as an `NSButton`'s mouse up,
  which is the event a click's stall waits on.
- **An `NSEvent` local monitor.** Leaves undone: the same events as `sendEvent`, and two existing monitors can consume
  events before it in an undocumented order (`Packages/UnitermKit/Sources/QuestionsApplet/FieldWidget+Pickers.swift:64`,
  `Packages/UnitermKit/Sources/MapViewerApplet/MapViewerView.swift:225`).

Decision: the event tap plus the `nextEvent` override, when a listen-only tap on uniterm's own process works without a
new privacy grant. When it needs one, the `nextEvent` override alone. M2 checks the grant first, on a machine where the
debug build holds none.

Rationale: only the pair answers "did the event reach uniterm" and "did AppKit take it" separately. A tap the system
disables for answering slowly receives a disabled-by-timeout event, so the record logs that gap rather than hiding it.
A grant would add a setup step on every developer machine and the CI image, and a machine without it would lose the
tap's records quietly, so a grant rules the tap out. Without the tap, the one gap left is an event delivered and never
dequeued. In the Cmd-T stall, uniterm's event loop processed other events every 8 ms, so that gap is the least likely
explanation there. A probe on this machine showed `-[NSApplication run]` goes through the public `nextEvent` override.
The app starts from `@main` with `NSApplication.shared` (`App/Main.swift:12`), and the debug environment is read
before it, so the subclass is made shared only when a UI test asks.

### What each record holds

Original question and candidates: the times, the event's identity, whether to record characters, the keyboard holder,
the mouse position and hit view, and non-input records for activation and key-window changes.

Decision: each record holds:

- The time the app took the event, and the event's own `timestamp`
- The event type and its source, telling XCTest's events from a person's
- For an event XCTest sent, its key code and modifier flags. For a key event from any other source, or one whose
  source cannot be read, no key code and no flags
- No characters
- The key window's number, and the first responder's class and accessibility identifier, read before the event acts
- For every mouse event, its window number and its location in that window. For presses, releases, and wheels only,
  the class of the view it hits, and that view's accessibility identifier when it has one
- A record when one of uniterm's windows becomes key or stops being key

Rationale: the two times separate a main thread that held an event from an event that arrived late. The source tells
a person's stray pointer, a logged cause, from XCTest's moves. XCTest synthesizes keys by key code, so the key code and
flags name the key, and characters would add no evidence while putting typed text in the system log store, readable by
an administrator for days. A person's key codes and flags would recover their typed text just as fully on a known
layout, such as a password typed while the test window held the keyboard, so a person's key events keep only their
type, source, and times. That still shows a person typed during the test. Amended 2026-11-25; see Decision Log. A hit test on every move would add main-thread work at about 100 moves a second, which
could change the timing the record exists to observe. When another app's non-activating panel takes the keyboard,
uniterm stays active, so the frontmost record misses it, but uniterm's key window should lose key status. The
key-window record catches that. App activation needs no in-app record, since the runner's frontmost record logs it on
the same clock.

### Which events the app records

Original question and candidates:

- **Keys, buttons, scroll, plus moves and drags.** Key-downs, key-ups, modifier flag changes, presses and releases of
  every mouse button, scroll wheels, pointer moves, and drags.
- **Keys and mouse.** As above, without moves and drags. Leaves undone: hover gestures, drag paths, and a person's
  stray pointer go unrecorded.
- **Keys only.** Leaves undone: the `StatusBarUITests` click sighting and the `LauncherUITests` wheel flake.
- **Every event type.** Adds app-defined, system-defined, and periodic events, which serve no named sighting and add
  volume to the one log the evidence lives in.

Decision: keys, buttons, scroll, plus moves and drags. Converged in 2 passes.

Rationale: XCTest's log shows that a synthesized click sends its moves and its mouse down without waiting, and waits
only on the mouse up, so a click's stall is its mouse up. Moves still matter. The suite hovers, drags, and right-clicks
at 14 sites, and a person's stray pointer caused the `TerminalLinkUITests` entry, where 179 pointer lines arrived
during a 2 s idle wait (`spec/flaky-tests.md:115`). While uniterm was active, M2 recorded moves over every view it
tried, in a main window and in Settings, though only the terminal surface asks for them. AppKit merges queued moves,
so about half of XCTest's moves leave a record of their own, and a gap in the move records is not proof that nothing
moved. Amended 2026-11-25; see Decision Log. The volume is bounded by XCTest's moves plus any physical pointer, about
100 a second.

### Where the app writes the record

Original question and candidates:

- **The unified log, through `Logger` at the default level.** Each record lands in the kept log beside the event
  lines, on one clock, inside the test's marks. It survives the app being killed.
- **Both the unified log and a file.** Leaves undone: nothing the log misses, except a run that cannot read the system
  log, where XCTest's event lines are missing too and the records cannot be matched to unconfirmed events.
- **A file the base class names.** Leaves undone: a test the execution-time allowance ended never reaches teardown, so
  the hang cases carry nothing.

Decision: the unified log, through `Logger` at the default level. Converged in 1 pass.

Rationale: it shares one artifact and one clock with the event lines, the test marks, and the frontmost lines, and it
survives a kill and a test the allowance ended, for the same reasons the earlier decisions chose the log. The app
already logs under the `dev.uniterm.app` subsystem (`App/AppDelegate.swift:28`). The kept log selects only the
recording category in the test app's process, so lines from a developer's own running uniterm never land in an
artifact. Marked-public fields sit in the system log store for days, readable by an administrator, which bears on
whether a record holds typed characters.

## Design Decisions (Open)

None.

## Risks

- **testmanagerd's log changes with an Xcode release** — likelihood: medium, impact: medium. Mitigation: the lines are
  Apple's own, with no stated format. M1 records the Xcode version whose lines it reads. A run whose kept log has no
  event lines at all says so, rather than leaving an empty file that reads as "nothing happened".
- **A CI runner hides the log** — likelihood: low, impact: high. Mitigation: the lines are at the default level, which
  the system keeps. M6 checks that a failed CI run's kept log holds them. Amended 2026-11-25; see Decision Log.
- **Unconfirmed does not mean undelivered** — likelihood: medium, impact: medium. Accepted: a confirmation that never
  came can come from an event that arrived and posted no notification. The kept log says which events went
  unconfirmed, not why. The frontmost record narrows it, and M2's in-app record answers the rest.
- **The frontmost record misses a window that takes the keyboard without activating its app** — likelihood: low,
  impact: medium. Accepted: a system authentication prompt or a non-activating panel can take keys while the frontmost
  app stays uniterm. The record then reads "uniterm frontmost" for a key that went elsewhere. A sighting whose record
  shows uniterm frontmost throughout leaves that cause open, and the entry says so. Amended 2026-11-25: uniterm's
  key-window record should catch it, which M2 checks.
- **A run cannot read the system log** — likelihood: low, impact: high. Mitigation: a CI image or a local account
  whose user cannot read the log store would fail `log show` on every failure, and every sighting would again end "not
  confirmed". M1's check that a failed `log show` says so detects it at the first failure. The in-app record is lost
  then too, which is accepted: without XCTest's event lines, its records could not be matched to unconfirmed events.
- **Keeping the log adds time to a failed CI job** — likelihood: medium, impact: high. Mitigation: a `log show` over a
  full suite's window runs after the tests, inside the job's time limit. If it pushed the job past the limit, the job
  would be cancelled, and its upload, the test results included, would never run. M6 measures it on a failed shard.
  M7 requires the results and the kept log to upload even when the job reaches its limit. Amended 2026-11-27; see
  Decision Log.
- **Recording changes the timing it measures** — likelihood: medium, impact: medium. Mitigation: pointer moves arrive
  at about 100 a second. In the `TerminalLinkUITests` entry, only the pointer moves and the debug logging differed
  between a failing and a passing run. M2 measures the cost over a burst that includes moves, and skips the hit test
  for moves. M5 requires the Cmd-T stall to still reproduce at about its usual rate with recording on. Amended
  2026-11-25; see Decision Log.
- **The recorder watches a person's input on a developer's machine** — likelihood: low, impact: medium. Mitigation:
  no tap ships, since M2's probe found that it needs a privacy grant. The `nextEvent` override records only in a debug
  build, and only when a UI test launch asks. A person's key events keep no key code and no flags, so typed text never
  reaches the log. Amended 2026-11-25; see Decision Log.
- **UTERM-044 lands its per-shard upload without the kept log** — likelihood: medium, impact: low. Mitigation: UTERM-044
  M1 is ahead of this proposal in the queue, and its checks name only the test results. M6 here carries the check that
  each failing shard's upload also carries its kept log. Amended 2026-11-25; see Decision Log.
- **The evidence shows a cause that no test-side change can fix** — likelihood: medium, impact: low. Accepted: knowing
  that the runner drops events is itself the finding. It moves the entries from "suspected" to a known cause, and the
  next step is a report to Apple or a change to how CI runs.

## Milestones

### M1: A failed run keeps where its input went

**Status:** DONE

- A failed local UI run keeps the `testmanagerd` log for the run, and says where in its output
- A kept log shows each numbered event of a failing test's gestures, and whether it was confirmed or timed out
- A failing test carries the record of which app was frontmost while it ran
- A passing run keeps nothing new
- A kept log with no event lines says so
- The Xcode version whose lines M1 reads is recorded in the As built block
- The kept log's window starts after the run holds the screen lock, so another run's lines never fall inside it
- A `log show` that fails says so in the run's output and in the kept file. The Accessibility hint still prints, and
  the script still exits 1
- `log show`'s time on a failed full suite is measured locally and recorded in the As built block
- The kept log's path is passed to the script explicitly, not parsed from the `xcodebuild` command. A later failed run
  replaces an earlier run's kept log rather than piling up beside it
- Each frontmost change is logged within 100 ms even while XCTest waits on a synthesized event's confirmation. When
  the runner's main thread is blocked through that wait, the observer runs off the main thread
- The kept file is compressed or sized so the upload stays within the artifact limits
- The frontmost record holds the frontmost app when the test started, not only the changes
- Each frontmost change's logged time is within 100 ms of the change, shown by activating another app during a
  synthesized key
- The runner's frontmost lines are at the default level, and the kept log's predicate includes them
- The test marks, issue marks, and frontmost lines show their names in `log show` output, not `<private>`
- Every test's start mark comes before its first gesture, and its end mark after its app ends, including in a
  subclass that overrides setup or teardown
- A kept log holds each failing test's start mark and its issue marks. A test the execution-time allowance ended
  carries its start mark and the next test's start, and the As built block records whether it also gets an issue mark

**As built:**

- Xcode 26.6 Build version 17F113 reads the lines M1 collects.
- The kept log is selected by the predicate `process == 'testmanagerd' OR subsystem == 'dev.uniterm.uitests'`. The
  subsystem match alone selects the runner's logs without matching the bundle path. The subsystem is unique to this
  runner.
- The kept log's path is passed via the `UNITERM_UI_KEPT_LOG` environment variable. The `test-app` and `test-app-select`
  targets set it to `.build/DerivedData-test/ui-test-kept-log.txt.gz`. The `test-app-shard` target sets it to
  `.build/DerivedData-test/ui-test-kept-log-shard-N.txt.gz`.
- The script `collect-ui-test-log.sh` checks whether the output path ends in `.gz` and applies gzip compression when it
  does. Without compression the kept log is a plain text file.
- Running `log show` over a 25-minute window with the predicate above takes 2.7 seconds locally.
- The frontmost attachment uses `lifetime = .deleteOnSuccess` so XCTest keeps it only when the test fails.
  `ThrowawayAttachmentTest/testAttachmentProof` failed deliberately and showed `Added attachment named
  'frontmost-record.txt'` at t = 0.73s in teardown. `BrowserRemoteUITests` passed without keeping any frontmost
  attachment in its bundle, confirming XCTest deletes the attachment on success.
- `ThrowawayTimingTest/testFrontmostTiming` launched Calculator during `typeText`. The kept log showed Calculator logged
  at 04:09:36.864. The test output showed the frontmost logger wrote the same change at 04:09:36.868731. The delta is
  4.7 ms. XCTest was blocked waiting on the synthesized key's confirmation during that interval.
- `ThrowawayAllowanceTest/testExceedsAllowance` slept for 125 seconds and hit the execution time allowance. The kept
  log showed both test start marks: `testAfterTimeout` at 04:10:03.844 and `testExceedsAllowance` at 04:10:05.597. A
  test the allowance ended keeps its start mark. The next test's start closes its bracket. No issue mark appeared for
  the timed-out test.
- `BrowserRemoteUITests` ran successfully with the kept log deleted beforehand. After the passing run the kept log file
  did not exist. Passing runs keep nothing new.
- The entire flow from `run-ui-tests.sh` to `collect-ui-test-log.sh` works. A failing run with `make test-app-select
  UI_TESTS=ThrowawayAttachmentTest` showed `Kept log written to: .build/DerivedData-test/ui-test-kept-log.txt.gz` at
  the end. The script chain collects and compresses the log.
- The test step has a 38-minute timeout. The job has a 50-minute timeout. The job timeout accounts for setup up to 5 min,
  then the test step, build included, up to 38 min, then collection up to 2 min and upload up to 5 min. A follow-up step
  collects the kept log if the test step didn't complete. It uses the start time recorded in `ui-test-start-time.txt`.
  The upload step runs on `failure() || cancelled()` to cover both outcomes.

### M2: The app records the input it receives

**Status:** DONE

Amended 2026-11-25; see Decision Log.

- Whether a listen-only event tap on uniterm's own process works without a new privacy grant is checked first, on a
  machine where the debug build holds none, and recorded in the As built block. The capture point follows "Where the
  app records an event"
- A debug build asked by a UI test records each event "Which events the app records" names. A debug build not asked,
  and every release build, records nothing
- When the tap is used, a tap the system disabled leaves a record saying so, and a run of the suite shows none
- When the tap is used, a tap that could not be created leaves a record saying so, so its missing records never read
  as "never delivered"
- When the tap is used, probing for it leaves no system privacy prompt on screen during a UI run
- When the tap is used, its callback runs off the main thread, shown by its records keeping their times while the main
  thread is blocked
- The base class asks every UI test launch to record, beside its other `UNITERM_` variables
- The recording category's fields show their values in `log show` output, not `<private>`
- A person's key event leaves a record with no key code and no flags, and an XCTest key event leaves one with both
- Another app's non-activating panel taking the keyboard leaves a key-window record in uniterm, or the As built block
  records that it does not
- A UI test sends a key, a modified key, a click on a plain view, a click on an `NSButton`, a right-click, a wheel, a
  hover, and a press-and-drag, and finds the records for each. Each event the capture point misses is named in the As
  built block, with which views see pointer moves
- The burst-cost measurement includes pointer moves
- The kept log selects only the recording category in the test app's process
- The cost of recording over a burst of synthesized events is measured with and without it, and recorded in the As
  built block

**As built:**

Times are local, on 2026-11-25.

- The grant probe ran inside the debug app, as pid 10469 at 09:33:39. `CGPreflightListenEventAccess()` returned 0.
  `CGEvent.tapCreateForPid` with `.listenOnly` on the app's own pid returned nil. tccd logged two
  `kTCCServiceListenEvent` checks for `dev.uniterm.app`, both "Auth Right: Unknown (None)" with preflight true. So the
  tap needs the ListenEvent grant, and the probe raised no privacy prompt.
- A standalone command-line probe also returned nil. tccd logged no check from it, so it did not test the grant.
- No tap code ships. The `nextEvent` override stands alone, as "Where the app records an event" settles for a tap that
  needs a grant. The tap's bullets apply only when it is used, and the CI image's grant check moved to M4. See Decision
  Log.
- The record is marked public in the log. This machine shows even private fields: a probe at 10:13:15, pid 1343, logged
  one value as private, as default, and as public, and all three showed it. So the earlier check of values against
  `<private>` did not test redaction. Marked public, the values show on a machine that redacts too. The proof run at
  10:44:37, pid 24177, holds no `<private>` field.
- A launch without `UNITERM_RECORD_INPUT` records nothing. At 10:18:28 a test relaunched the app without it, as pid
  21007. XCTest's key reached it, confirmed by AX, and so did a click. `log show` held no `dev.uniterm.app` line for
  that pid. The same test's first launch, pid 20995, logged "Recording input" and `window_became_key`. Fifteen
  iterations of the shortcut test with recording off, from 10:38:08, logged no recording line either.
- A Release build made after this milestone's last code change has none of the recorder's symbols in `nm -U`. Its
  binary holds no "input-recording" string, where the debug build's holds one.
- Every recording launch logs "Recording input" at the default level, which marks the pid in a kept log. A launch that
  finds the shared application already made logs an error and records nothing.
- A key counts as XCTest's when its user data is nonzero and `testmanagerd` posted it, read from its source pid. Only
  then does its record hold a key code and flags. Another program that posts keys with user data, such as a password
  manager typing for a person, gets neither.
- Keys posted inside the app at 10:01:23, as pid 48383, carried `source_pid=48383` and no key code or flags. XCTest's
  keys in that run carried both. In the proof run at 10:44:37, all 60 of XCTest's key events carried both.
- A person's hardware events carry `source_userdata=0 source_pid=0 source_stateid=1`. From 10:17:52 to 10:18:45, a
  person's moves, scrolls, and keys reached the test app as pids 18272, 19479, 20995, and 23262. Their key records hold
  no key code and no flags. Those moves then crossed uniterm's window, and WezTerm was activated at 10:18:13. That is
  the only outside activation in this milestone's frontmost records. The hover and cost results below come from later
  runs with no such input.
- A press's hit test starts at the window's frame view. The frame view has no superview, so `hitTest` takes window
  coordinates, which `locationInWindow` already is. A probe at 10:13:15, pid 1343, found the frame view, an
  `NSThemeFrame`, at the origin with the window's 960 by 640 size and no superview.
- At 10:17:48, pid 18045, a click on the title bar's close button landed at (16, 624). That is the button's center
  from its screen frame. Its press and release name `_NSThemeCloseWidget`.
- A record names the class of the view a press hits, and its identifier when it has one. See Decision Log.
- The proof run of `InputRecordingProofTest` at 10:44:37, as pid 24177, has a record for each kind of input it
  sends. Each of its 30 key downs and 30 key ups has one, including Cmd-T, with key code 17 and flags `0x100000`. Its
  click and right-click on the terminal name `GhosttySurfaceView`. Its scroll, hover, and drag have records too.
- In that run, the close button's press and release name `_NSThemeCloseWidget`, and its sheet opened. Cancel's press
  and release name `_NSAlertButton`, and the sheet closed. `log show` found these records after the run, since the
  sandboxed runner cannot read the log. The test passed again at 10:53:34, after the milestone's last change.
- An `NSButton`'s tracking loop dequeues through the override. A throwaway stack probe at 10:29:26, pid 54517, caught
  the close button's mouse up being taken inside `-[NSButtonCell trackMouse:inRect:ofView:untilMouseUp:]`, under the
  button's `mouseDown:`, by the override. The button's action then fired.
- On macOS 26.7.3, not every button tracks that way. The alert's Cancel button and the Settings segmented control took
  their mouse up from the main loop, at 10:29:23 and 10:29:30. Their records hold both press and release.
- The Settings window's events are recorded. An earlier attempt found no record of a click on its segmented control.
  At 10:18:33, pid 21647, and again at 10:29:30, pid 54845, that click's press and release were recorded, with the
  control's class and identifier. The earlier miss did not recur, so its cause is unknown.
- Moves are recorded over every view tried while uniterm is active. In a run from 10:24:52, pid 39721, each hover sent
  24 moves. The records inside each view were: terminal 10, tab bar 12, status bar 11, whole content area 11, title bar
  11, and Settings window 13. Only the terminal surface asks for moves, yet AppKit delivered them over all of both
  windows. See Decision Log.
- The capture point misses two things the tests sent. AppKit merges queued moves, drags, and scrolls, so the merged
  ones have no record of their own. In the proof run at 10:44:37, 82 of 168 moves, 99 of 275 drags, and 2 of 4 scroll
  events had one. The gaps in the records' user data show which merged.
- The other miss is a press on the menu bar, since menu tracking takes it outside the override. At 10:26:41, pid 44983,
  the File menu's mouse down had no record. Its mouse up, the moves over the open menu, and the Escape that closed it
  did. The menu also posted the Escape's key up again, so that event has two records with the same user data.
- Another app's non-activating panel leaves a key-window record. At 10:25:11, pid 40565, a test pressed Cmd-Space,
  which opened Spotlight. The Command down was recorded. The Space down, sent at 10:25:11.603, had no record, and
  uniterm logged `window_resigned_key` 17 ms later. The Space down and up each timed out at 5 s, and the frontmost
  record showed no activation.
- The Command up, at 10:25:21.703, was recorded, so modifier changes still reach the active app under the panel.
  Escape closed Spotlight at 10:25:22.744, and uniterm logged `window_became_key` 3 ms later.
- The cost was timed inside the app by a throwaway timer around the record path, with
  `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`. Three bursts of 40 keys, a drag, and 20 hovers ran from 10:25:46 to
  10:26:37, as pids 43085, 44032, and 44661. Each logged 400 records, about 210 of them moves, 108 drags, and 80 keys.
- The record path took 18.9, 17.0, and 18.3 ms in total over those bursts. Its mean was 47, 42, and 46 µs per event,
  and its maximum 155, 178, and 236 µs. Moves alone averaged 37, 38, and 41 µs.
- Timed from the test, the same bursts took 6649, 8076, and 7784 ms with recording on, a median of 7784 ms. With
  recording off they took 6714, 7983, and 6999 ms, a median of 6999 ms. Each condition spreads by about 1.3 s, more than
  the gap between the medians. The record path adds about 18 ms per burst, so the gap is XCTest's own variance.
- The shortcut test did not stall in 45 runs. With recording on, 15 separate runs from 10:32:15 and one run of 15
  iterations from 10:36:15 logged no confirmation timeout. With recording off, 15 iterations from 10:38:08 logged none
  either. Its usual rate is 3 of 9.
- Since neither condition stalled, these runs cannot show whether recording changes the rate. No T event went
  unconfirmed, so whether uniterm records one waits for a stall with recording on. M5 takes both Cmd-T checks. The
  test's flaky entry records the counts. See Decision Log.
- A failed run's kept log holds the recording lines and none of the app's other lines. A deliberately failing
  throwaway test at 10:47:48, pid 45815, left a kept log with its `testmanagerd` lines, the runner's marks, and that
  pid's four recording lines.
- The UI test build's two Sendable warnings in M1's frontmost observer are fixed. The frontmost record now lives in a
  queue-guarded box, which the observer holds without capturing the test case.

### M3: The flaky entries say what to look for

**Status:** DONE

- The `spec/flaky-tests.md` Rule section says that a sighting of a stalled event records which of its events went
  unconfirmed, and which app was frontmost
- Each of the four entries this proposal names says what its next sighting records
- The help for `make test-app` and `make test-app-select` names where a failed run's log lands

**As built:**

Times are local, on 2026-11-25.

- The Rule section gains a rule for a sighting of a stalled event. It names where a failed run keeps its log and the
  frontmost attachment. It says how the app's record of an event pairs with `testmanagerd`'s line for it, and what a
  missing record means.
- The pairing was read from M2's logs. In the deliberately failing run at 10:47:48, `testmanagerd` logged a key down
  as Event 81922. The app's record of it carries `source_userdata=81922` and `testmanagerd`'s pid. In the proof run at
  10:44:38, a mouse up paired the same way, as Event 81432. Command's "Key 55 down" at 10:44:41 recorded as
  `type=flagsChanged`, not `keyDown`.
- In that proof run, `testmanagerd` logged each click's mouse down as "not waiting for confirmation", and waited only
  on its mouse up.
- The status bar answers every hit test inside it, and it dismisses on the mouse down. So the status bar entry's next
  sighting reads the mouse down's record, whose hit view is the bar rather than the dismiss control.
- Each of the four entries gains a "Next sighting" line, the field the file's other entries already use. The shortcut
  entry's line says that M5 reads its next Cmd-T stall.
- The shortcut entry read "CI keeps no `testmanagerd` log, and UTERM-060 proposes keeping it." It now reads "The CI run
  kept no `testmanagerd` log." M1 keeps that log for a failed CI run, so the present tense no longer held.
- The help for `test-app` and `test-app-select` now ends by naming where a failed run keeps its event log. The
  `test-app-shard` help names its own file the same way.

### M4: The kept evidence on CI

**Status:** DONE

Amended 2026-11-25; see Decision Log.

- CI's upload path matches the kept log
- When the tap is used, M2's grant check for a listen-only event tap on uniterm's own process also runs on the CI
  image's macOS

**As built:**

Times are UTC, on 2026-11-26. No run has failed a shard, so this milestone proves the upload path by reading the files
that name it. See Decision Log.

- The kept log's path is the same in the Makefile's shard target, the scripts, the follow-up collection step, and the
  upload glob. The shard index in the file name is the job index on both sides. The start-time file is written where
  the follow-up step reads it.
- The upload uses `if-no-files-found: ignore`, so a mismatch would pass silently. M6 holds the only proof on a live run.
- Eight runs were inspected. One of them, 45749818748, predates the collection step. Its three shards skipped the upload
  step.
- Runs 45752629043, 45755641410, and 45760228289 are the pull request runs with the collection step. Both the
  collection step and the upload step were skipped on all three shards of each. The skipped collection steps ran at
  04:10:51 to 04:13:56 UTC for 45752629043, 04:38:33 to 04:44:17 UTC for 45755641410, and 05:24:28 to 05:25:47 UTC for
  45760228289. Attempt 1 of 45755641410 failed its `package` job, not a shard. Its three shards passed.
- The other four runs are main pushes, 45751929530, 45754927772, 45759466625, and 45762275495. Their `app` job was
  skipped, since a merged pull request had passed the same tree.
- All eight artifact lists are empty. A passing run uploads nothing. This matches "A passing run keeps nothing new".
- No path mismatch or bug turned up. Whether an upload from a failed shard reaches the artifact store waits on a failed
  shard. M6 takes it.
- The tap bullet does not apply, since no tap code ships. It applies only if a tap is added later. See M2's As built
  block.

### M5: The recorder sees a Cmd-T stall

**Status:** NOT STARTED

Waits for a stall seen in an ordinary local run or in a kept CI log. No run repeats the shortcut test to find one.

Amended 2026-11-27; see Decision Log.

- With recording on, the shortcut test still reproduces the Cmd-T stall at about its usual rate
- A run of the shortcut test alone that reproduces the Cmd-T stall shows, for the unconfirmed T events, whether
  uniterm recorded them. The result goes in the As built block and in the test's flaky entry

### M6: A failed CI shard keeps its evidence

**Status:** DONE

Amended 2026-11-27; see Decision Log.

- A failed CI `app` job uploads the same log with its test results
- `log show`'s time on a failed shard is measured on CI and recorded in the As built block
- Each failing shard's upload carries its own kept log

**As built:**

All clock times here are UTC, on 2026-11-27. The proof is the first two failed shards on CI: `app (0)` of run
46052402044, and `app (1)` of run 46055769038. Both are attempt 1 of a pull request run.

- Each failed job uploaded one artifact, named for its shard and attempt. `ui-test-results-shard-0-attempt-1` is
  6,081,023 bytes, and `ui-test-results-shard-1-attempt-1` is 5,876,874 bytes. Each holds two `.xcresult` bundles and
  that shard's kept log, `ui-test-kept-log-shard-0.txt.gz` and `ui-test-kept-log-shard-1.txt.gz`.
- The CI runner does not hide the log. Shard 0's kept log holds 152,154 lines. Of them, 134,366 name `testmanagerd`,
  75 are "Recording input" lines, and 4 are "confirmation delay timeout" lines. Shard 1's holds 97,886 lines, with
  84,732, 76, and 10 of the same. Both hold the runner's frontmost lines.
- `log show` took 8.4 s on shard 0, from 19:04:49.6 to 19:04:58.1. It took 7.0 s on shard 1, from 19:32:26.9 to
  19:32:33.9. Each covers one shard's window. The jobs ended 14:38 and 12:22 after they started, against a limit of 50
  minutes.
- Each run had one failed shard, and each upload carries the log with its own shard's index. No run has yet had two
  shards fail together.
- In both jobs the follow-up collection step ran after the test step had already collected the log, and wrote over
  it. The uploads carry the second copy, so the counts above come from it. See
  `spec/bugs/20261127-ci-kept-log-collected-twice-on-a-failed-shard.md`.
- The artifacts expire on 2026-12-04, after 7 days.
- The upload at a job's time limit moved to M7. See Decision Log.

### M7: The evidence uploads at a job's time limit

**Status:** NOT STARTED

Split from M6 on 2026-11-27; see Decision Log.

- The test results and the kept log still upload when a CI `app` job reaches its time limit

## Decision Log

- 2026-11-25: Drafted from the `ShortcutOwnershipUITests` sighting on #109, as an in-app receipt log. The user chose keys
  and mouse over keys only, and the log on every failure over only the waits that call `focusReport`.
- 2026-11-25: The draft's first critique pass added the system-log question, the `nextEvent` capture point, the
  activation and click-location fields, the event-timestamp matching candidate, and the off-main-thread writes. It
  dropped the release-binary check, since CI builds no release configuration and the other debug hooks rely on
  `#if DEBUG` alone.
- 2026-11-25: The re-check converged. The test-side marker candidate stayed open, and the event-source field was marked
  as an addition.
- 2026-11-25: Review start: 2 milestones, 4 settled decisions, 5 risks, no Live after lines or row gates, no
  out-of-scope statements; the proposal at "Draft UTERM-060 to record the input a UI test's app receives". The user
  asked for a review of the open questions.
- 2026-11-25: The review found that `testmanagerd` already logs each synthesized event's confirmation or its 5 s
  timeout, and that CI discards that log. The user retargeted the proposal: keep that log for a failed run, record which
  app was frontmost, and defer recording inside the app. This dropped the settled decisions "A debug-only hook",
  "Keys and mouse", and "Every failure gets the log", and the five open questions about the in-app record. The draft
  read: "A debug build of uniterm records each key and mouse event it receives to a file that a UI test names."
- 2026-11-25: A local run reproduced the shortcut test's failure at Cmd-T, 3 stalls in 9 iterations. The T key's down
  and up each timed out at 5 s while Command down and up were confirmed, and uniterm's event loop kept sending other
  event notifications. The Motivation records it.
- 2026-11-25: The UI run script keeps the log after a failed run, since it covers local and CI runs and a test the time
  allowance ended. Failure diagnostics stay off, for the screen recordings they attach. (autonomous)
- 2026-11-25: The kept log holds every `testmanagerd` line, plus the runner's frontmost lines, since a filter drops the
  evidence that uniterm's event loop ran. (autonomous)
- 2026-11-25: The base class records the frontmost app at test start and each activation change, logged at the default
  level and attached on failure, so a test the time allowance ended still leaves its record. (autonomous)
- 2026-11-25: The runner marks each test's start and end and each recorded issue in the unified log, so the kept log
  reads on its own and shows the events just before a failure. (autonomous)
- 2026-11-25: Correction of fact in "Defer recording inside the app". The rationale read: "in all four sightings the
  stall durations point to unconfirmed events. An in-app record sees nothing of an event that never reached uniterm,
  so it adds evidence only once an event was confirmed." That was wrong, and contradicted the risk "Unconfirmed does
  not mean undelivered": for an unconfirmed event, a record of it says it arrived, and no record says it did not. The
  Revisit line gained a second trigger, an event left unconfirmed while uniterm was in front, which the local Cmd-T
  reproduction matches in shape. The deferral stands. (autonomous)
- 2026-11-25: The coherence pass routed five checks to M1: the upload on a timed-out job, the kept log's explicit
  path, the frontmost observer under a blocked main thread, the allowance-ended test's marks, and the earlier redaction
  and placement checks. It added the risk that a run cannot read the system log. (autonomous)
- 2026-11-25: The deferral of the in-app record gained a revisit trigger on each of two review passes, and the user was
  asked about it. The user chose to build the record now, after the kept log, in a new M2, and dropped the deferral.
  "Defer recording inside the app" read: "Decision: deferred. The app records nothing about the input it receives."
  The flaky-entry milestone became M3. Four mechanism questions reopened. (addition)
- 2026-11-25: The app records keys, every mouse button, scroll, pointer moves, and drags, since the suite hovers,
  drags, and right-clicks and a stray pointer already caused one logged flake.
- 2026-11-25: The app writes each record to the unified log through `Logger`, in its own category, selected by the
  test app's process, so it shares the kept log's clock and survives a kill.
- 2026-11-25: The app records at a listen-only event tap on its own process plus a `nextEvent` override, or at the
  override alone when the tap needs a new privacy grant, which M2 checks first. Only the pair separates an event never
  delivered from one never dequeued.
- 2026-11-25: Each record holds two times, the event's type, key code, flags, and source, the keyboard holder, the
  mouse window and location, and a hit view for presses, releases, and wheels. It holds no characters, and adds
  key-window changes, which catch a non-activating panel taking the keyboard. The user said these needed no question
  once the most correct option was clear.
- 2026-11-25: The final re-check found that a person's key codes and flags recover their typed text as fully as
  characters would. "What each record holds" read: "The event type, key code, modifier flags, and its source, telling
  XCTest's events from a person's". Key codes and flags are now kept only for XCTest's events. This was the proposal
  loop's third pass, so the fix was not re-checked. (autonomous)
- 2026-11-25: The risk review added three risks: recording changes the timing it measures, the event tap watches a
  person's input, and UTERM-044 lands its per-shard upload without the kept log. It corrected the CI time-limit
  risk's mitigation to the upload M1 requires. No risk is high in both likelihood and impact. (autonomous)
- 2026-11-25: M3 keeps its change to the `spec/flaky-tests.md` Rule section and its help text for `make test-app` and
  `make test-app-select`, so every sighting reads the kept evidence and a local failure says where it lands.
  (addition)
- 2026-11-25: Review gate: kept all. The final re-check's privacy fix to "What each record holds" was not re-checked.
  No decision earns an ADR.
- 2026-11-25: Accepted.
- 2026-11-25: Scheduled as UTERM-060 M1-M3 in queue.md, after UTERM-044 M1.
- 2026-11-25: M4 "The kept evidence on CI" split from M1 by amendment, as a run best guess, since the run never pushes.
  M1's bullet "A failed CI `app` job uploads the same log with its test results" moved to M4 verbatim. The CI half of
  M1's "`log show`'s time on a failed full suite is measured and recorded in the As built block. The test results and
  the kept log still upload when the job reaches its time limit" also moved to M4. The local measurement and the CI
  measurement are split. The bullet "When UTERM-044's shards land, each failing shard's upload carries its own kept log"
  moved to M4 verbatim. Three risk mitigations amended to name M4 where they named M1 for CI checks: "A CI runner hides
  the log", "Keeping the log adds time to a failed CI job", and "UTERM-044 lands its per-shard upload without the kept
  log". Each amended risk carries a marker. M1's kept log still uploads with the test results when the job reaches its
  time limit. Queue row `| UTERM-060 M4 | UTERM-060 M3 | <note: needs a pushed CI run> |` added after UTERM-060 M1-M3.
  (run best guess)
- 2026-11-25: Correction of fact in M1's kept-log path bullet. The original read: "The kept log's path is passed
  explicitly, not parsed from the `xcodebuild` command. A later failed run replaces an earlier run's kept log rather
  than piling up beside it, and CI's upload path matches it". The CI-upload-path half moved to M4 as a new bullet.
  (autonomous)
- 2026-11-25: Correction of fact in M1's `log show` bullet. The original read: "`log show`'s time on a failed full suite
  is measured and recorded in the As built block. The test results and the kept log still upload when the job reaches
  its time limit". The CI-upload half moved to M4's split entry. The measurement is now local only. (autonomous)
- 2026-11-25: M2's grant probe found that a listen-only event tap on uniterm's own process needs the ListenEvent grant,
  which the debug build does not hold. In the debug app, `CGPreflightListenEventAccess()` returned 0, and
  `CGEvent.tapCreateForPid` returned nil. tccd checked the grant twice, as a preflight, and raised no prompt. As "Where
  the app records an event" settles for that case, the `nextEvent` override stands alone, and no tap code ships.
  (run best guess)
- 2026-11-25: Three M2 bullets now apply only when the tap is used, since none ships. They read: "A tap that could not
  be created leaves a record saying so, so its missing records never read as "never delivered"", "Probing for the tap
  leaves no system privacy prompt on screen during a UI run", and "The tap's callback runs off the main thread, shown
  by its records keeping their times while the main thread is blocked". The disabled-tap bullet already said so. The
  risk "The event tap watches a person's input on a developer's machine" became "The recorder watches a person's input
  on a developer's machine". Its mitigation read: "it is listen-only, in a debug build, and only when a UI test launch
  asks." (run best guess)
- 2026-11-25: M2's sentence "The grant check also runs on the CI image's macOS" moved to M4 by amendment, since only a
  pushed run reaches the CI image. It came from a bullet that now applies only when the tap is used, so it carries that
  condition to M4. The local probe already rules the tap out, so the CI check records the image's answer and cannot
  change the capture point. (run best guess)
- 2026-11-25: "What each record holds" read: "For presses, releases, and wheels only, the identifier of the view it
  hits". A record now names the hit view's class, and its identifier when it has one, as it does for the first
  responder. Many hit views have no identifier, such as the title bar's close button, and the class alone tells a
  button from a plain view. (run best guess)
- 2026-11-25: Correction of fact in "Which events the app records". The rationale read: "Moves reach the app only over
  views that accept them, such as the terminal surface's tracking area, so a gap in the move records is not proof that
  nothing moved." M2 recorded moves over every view it hovered while uniterm was active, in a main window and in
  Settings. A gap still proves nothing, since AppKit merges queued moves. (run best guess)
- 2026-11-25: M5 "The recorder sees a Cmd-T stall" split from M2 by amendment, since 45 local runs reproduced no stall:
  30 with recording on and 15 with it off. M2's bullets read: "With recording on, the shortcut test still reproduces
  the Cmd-T stall at about its usual rate, and the burst-cost measurement includes pointer moves" and "A run of the
  shortcut test alone that reproduces the Cmd-T stall shows, for the unconfirmed T events, whether uniterm recorded
  them. The result goes in the As built block and in the test's flaky entry". M2 keeps the burst-cost half of the
  first. M5 takes the stall half of the first and the whole second, verbatim. M5 waits for a stall with recording on,
  in a local run or in a kept CI log. The risk "Recording changes the timing it measures" now names M5 for the stall,
  where it named M2. Queue row `| UTERM-060 M5 | UTERM-060 M2 | Needs a Cmd-T stall with recording on. It advances
  only when the shortcut test stalls |` added after UTERM-060 M4. (run best guess)
- 2026-11-25: M6 "A failed CI shard keeps its evidence" split from M4 by amendment, since no CI shard has failed since
  the kept-log upload landed, and this run can neither push nor rerun CI. Eight upstream runs ran. No shard failed, and
  none uploaded an artifact. M4's bullets read: "A failed CI `app` job uploads the same log with its test results",
  "`log show`'s time on a failed full suite is measured on CI and recorded in the As built block. The test results and
  the kept log still upload when the job reaches its time limit", and "When UTERM-044's shards land, each failing
  shard's upload carries its own kept log". M6 takes all three, verbatim. M4 keeps "CI's upload path matches the kept
  log", which a static read proves, and the tap bullet, which does not apply. Three risks that named M4 for these
  checks now name M6: "A CI runner hides the log", "Keeping the log adds time to a failed CI job", and "UTERM-044 lands
  its per-shard upload without the kept log". The UTERM-044 impact line names no milestone, so it stays. Queue row
  `| UTERM-060 M6 | UTERM-060 M4 | Needs a shard to fail on CI. It advances only when one does |` added after
  UTERM-060 M5. The third bullet then read: "When UTERM-044's shards land, each failing shard's upload carries its
  own kept log". The shards have since landed, so M6 drops the condition. The check is unchanged. (run best guess)
- 2026-11-25: M4's tap bullet does not apply, since no tap code ships. The bullet stays in M4, and its As built block
  says so. The decision is M2's entry on the grant probe. (run best guess)
- 2026-11-27: 40 more local runs of the shortcut test alone, with recording on, reproduced no Cmd-T stall. The first
  run was 10 iterations, with testing from 02:59:43 to 03:00:29. The second was 30, with testing from 03:00:43 to
  03:03:02. All 40 passed, at about 4.6 s each by the runner's test marks. The saved `log show` output spans 02:59:42
  to 03:03:12. It holds 40 test starts, 40 test ends, and no issue mark. It holds no "confirmation delay timeout"
  line, so no Cmd-T event was even confirmed late. The 45 earlier runs bring the total to 85 runs with no stall since
  the 3-in-9 sighting. These runs cannot show whether recording changes the rate. They leave M5's check open. In one
  iteration, the log quarantined the app for high logging volume before its Cmd-T. None of that iteration's records
  reached the log. So a missing record is not proof that an event never reached uniterm, until a reader can see the
  quarantine. The kept log's predicate leaves the quarantine line out. The bug file is
  `20261127-input-records-lost-to-log-quarantine`. M5 stays NOT STARTED and keeps waiting for a stall with recording on.
  (run best guess)
- 2026-11-27: 40 more local runs of the shortcut test alone, in a second batch, reproduced no Cmd-T stall. The batch
  ran `make test-app-select` on `ShortcutOwnershipUITests/testARemapOntoAnAppletKeyWinsAndWarnsOnce`, under
  `caffeinate -dimsu`. It added `-test-iterations 40` to `UI_TEST_FLAGS`. It ran from 11:04:59 to about 11:08:15
  Pacific. Recording was on, as on every launch. No peer UI run was going. All 40 passed, each in 4.3 s to 5.3 s. The
  kept log's predicate was saved for 11:05:00 to 11:09:00. It holds 40 "Recording input" lines from 40 app processes.
  Each process has one Cmd-T key down record, with key code 17 and flags 0x100000. The log holds no "confirmation
  delay timeout" line, so no Cmd-T was even confirmed late. `log show --info --debug` for the window holds no
  QUARANTINED line. So no iteration lost its records to the quarantine that
  `20261127-input-records-lost-to-log-quarantine` describes. The total with no stall is now 125 runs since the 3-in-9
  sighting. These runs still cannot show whether recording changes the rate. M5 stays NOT STARTED and keeps waiting for a stall with recording on. (run best guess)
- 2026-11-27: M6 amended and finished, and M7 "The evidence uploads at a job's time limit" split from it. The user
  chose this. M6's second bullet read: "`log show`'s time on a failed full suite is measured on CI and recorded in the
  As built block. The test results and the kept log still upload when the job reaches its time limit". CI runs the
  suite in three shards since UTERM-044, so no CI job runs a full suite, and no job has reached its time limit. The
  measurement now reads "on a failed shard". The time-limit sentence moved to M7, which waits for a CI `app` job to
  reach its limit. M6 closed on the two failed shards of 2026-11-27. The risk "Keeping the log adds time to a failed CI
  job" read: "M6 measures it on a failed full suite, and requires the results and the kept log to upload even when the
  job reaches its limit." It now names M6 for the shard measurement and M7 for the upload. Queue row
  `| UTERM-060 M7 | UTERM-060 M6 | ... |` added after UTERM-060 M5. M6's row moved to history ahead of M5's, since M6
  needs nothing from M5.
- 2026-11-27: No run repeats the shortcut test to find M5's stall. The user chose this after 125 runs with no stall
  across four batches. M5 keeps its checks and stays NOT STARTED. It waits for a stall seen in an ordinary local run
  or in a kept CI log. Whether recording changed the stall's rate stays open until then. M5 had no goal line before.

## References

- `spec/flaky-tests.md`: the four entries named in Motivation
- UTERM-045: Settle input before UI tests send it
- `scripts/run-ui-tests.sh`: the wrapper every UI run goes through
