# UTERM-046: Make the Logged Package-Test Flakes Deterministic

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-25

## Impacts

- UTERM-044 — Risks: "Splitting moves a flake rather than fixing it" names this proposal as part of the fix.

## Summary

Two package-test flakes fail CI on a loaded runner with no change to the code. The browser's hung-process tests give a
spinning page 0.3 s of real time and expect it to use half a core. The script fixtures miss a helper's exit and hang.
This proposal makes both deterministic. Each regression the tests name stays caught. One live-sample claim that cannot be
checked independently of load, that a real spinning page reads busy, gives way to a stronger check of the reading's
units. It also closes the reused-id race in every package test that signals a process by its id. A test's own helper
signals through the fixture's handle. A process the product, libghostty, or WebKit reaps is signalled by a fresh
audit token after a start-time check, where the system gives a token. Where it does not, the process is signalled by
pid after the same check. The product's two check-then-signal sites, the content-process kill and the REPL helper
reaper, move to the same guarded call.

## Motivation

The browser test `BrowserHungProcessTests.testClosingASpinningTabEndsItsProcessWhenTheBoundRunsOut` failed on #91's CI.
Its assertion at line 294 found no signal sent: `[] is not equal to [12101]`. The test already runs the bound by hand
through `ManualHangTimer`. What it does not control is the sample. Before firing, it waits 0.3 s of real time in
`letTimePass` (`BrowserHungProcessTests.swift:183`). `ClosedProcessWatch` then signals only when the page used at least
`busyShare`, half a core, over that window (`Sources/BrowserApplet/WebContentProcess.swift:149,169`). The suspected
cause, not confirmed: on a loaded runner a spinning page can get less than half a core. The watch then rightly sends
nothing, and the test fails. Six more
places in the same class use `letTimePass` (lines 289 to 510), and one test asserts each side of `busyShare` against
live samples (lines 330 and 331).

`ScriptFixtures.finish` (`Tests/ScriptHostTests/Support.swift:214`) has hung three times, logged in
`spec/flaky-tests.md`, and each time the 120 s hang guard aborted the run. Two of the samples show it blocked in
`waitUntilExit`, and one of those shows the helper had already exited. The first sighting shows only a wait, with the
listener idle. Its
watchdog sends SIGTERM at 60 s and SIGKILL at 70 s, but only while `isRunning` reads true, so it cannot rescue an exit
Foundation missed.

The first draft of this proposal framed both as clock problems. Neither is. The browser test already injects its bound,
and the fixture waits on a process exit, not on time. The exec driver's stall test, also named in that draft, was
already fixed by "Measure stalled emits against the same emits to a reading driver", and its production bound counts
bytes, not time.

## Design Decisions (Settled)

### Production keeps its rules

Decision: production code keeps its bounds, its time sources, and its `busyShare`. A test seam replaces only what the
test supplies, never the rule the production code applies. The one planned production change is how two kills name
their target. `WebContentProcess.kill` and ScriptHost's `ProcessReaper` signal through `ProcessInspection`'s guarded
call, by a fresh audit token where the system gives one. Separately, "Keep a stopped exec driver from reading as
exited" fixed a bug found along the way: the exec driver's transport took a paused driver for one that had exited.
Amended 2026-11-25; see Decision Log.

Rationale: the hung-process bound and the busy-share rule are how a hung page stays contained, per ADR-07. A test
shortcut that weakened them would trade a flaky test for a weaker product. Signalling by token keeps every rule. It
only stops a kill from reaching a process that took a freed pid.

### No new waits on the product's main thread

Decision: making a test deterministic never adds a wait to the product's main thread. A test's own awaited polls are not
covered by this decision.

Rationale: ADR-08 says the main thread never waits on work whose duration uniterm does not bound. It governs the
product, not the test harness.

### How the test waits for the process to end

`waitUntilGone` polls for up to 15 s. The WebContent process is not the test's child, so `waitpid` cannot see it.

- **Keep the poll.** It already waits for an event, with a deadline.
- **Wait on the exit event.** `DispatchSource.makeProcessSource` with an `.exit` event mask reports the end of any
  process the test can see.

Decision: keep the poll.

Rationale: the poll already ends on the event, `kill(pid, 0)` reporting `ESRCH`, under a 15 s deadline. No logged failure
came from it. The failure logged at line 178 followed from no signal being sent. An exit source would add a kqueue
source and a check for a process that ended before the source was armed, and it protects against no named failure.

### How the fixture waits for its helper

- **The fixture reaps its own helper.** `start` spawns the helper with `posix_spawn`, and one thread per helper waits on
  it with `waitpid`. Signals go only before that reap, and a process id cannot be reused until its parent reaps it, so
  the watchdog can never signal another process. `HelperHost`'s `HelperProcess` and the exec driver's transport already
  work this way. `start` then returns the fixture's own handle instead of a `Process`, so every caller moves to it,
  including the callers that read `isRunning`, `terminationReason`, or the process id today.
- **A termination handler.** `finish` resumes when Foundation's `terminationHandler` fires, after reading both pipes.
  `start` already sets one for `onExit` callers, so `finish` must chain to it. It relies on Foundation's exit report,
  which is the mechanism the second sighting suggests missed an exit.
- **`waitid` with `WNOWAIT` beside `Process`.** `finish` sees the exit without reaping it and takes the status from the
  `siginfo`. Foundation stays the only reaper. The watchdog and the callers keep reading `Process`.
- **`waitpid` beside `Process`.** Foundation also reaps the children it launches. With two reapers on one process id,
  only one gets the status: the other gets `ECHILD`, or leaves `Process` with an undefined state that the watchdog's
  `isRunning` gate then reads.

Decision: the fixture reaps its own helper. `start` spawns with `posix_spawn`, a thread per helper reaps it with
`waitpid`, and `start` returns the fixture's own handle. Every caller of `start` and `finish` moves to that handle,
including every caller that builds its own `Process` and hands it to `finish` today.

Rationale: it is the only option that holds under both readings of the second sighting. The hang guard's `ps` listing
shows zombies, so "no child of `xctest` alive" means the helper had already been reaped. Either Foundation reaped it and
never woke `waitUntilExit`, or another reaper in the same process took it. Only a fixture that is the sole reaper of its
own child is immune to both. It is also the only option that keeps the watchdog off a freed process id. With
`isRunning` stuck true after a reap, today's watchdog sends SIGTERM and SIGKILL to an id the system may have handed to
another process. The termination handler and `waitid` both keep that `isRunning` gate, so neither can meet M2's check
that the watchdog never signals an exited process. Under a foreign reaper, `waitid` also falls back to reading
`terminationStatus` on a task that reads as running, which raises instead of returning.

Leaves undone: test code in `ScriptHostTests` that waits on Foundation's exit report outside the fixture, and never
signals its helper, keeps doing so. These are the `waitUntilExit` in `ScriptBindingTests`, `CommandHelperSandboxTests`,
and `skipUnlessSystemIntegrityIsOn`, and the two `waitUntilExit` calls in `ControllerRunTests`. None has a logged
failure. See the audit decision below. The sites that signal their helper by process
id move to the fixture's handle in M3. Amended 2026-11-23; see Decision Log.

### How far the audit goes

- **Logged flakes only.** The two above, and each new entry as it appears.
- **Every real-time wait in the package tests.** Classify each as a wait for an event, a deadline guard, or a real
  sleep, and fix every sleep that stands in for an event. The calls cluster in the terminal session integration tests,
  the exec pane tests, the exec driver channel tests, and the Markdown viewer tests. This is an addition, and it needs
  its own milestone.
- **Same mechanisms elsewhere.** Replace every other `waitUntilExit` in the package tests, about 15 sites in 7 targets,
  and every other live CPU-share window. This is an addition, and it needs its own milestone.
- **The fixture's neighbors.** After M2 holds on CI, move the other Foundation exit waits in `ScriptHostTests` that the
  fixture decision leaves undone. This is an addition.

Decision: logged flakes only, plus every package test that signals a process by its id. New flakes go through
`spec/flaky-tests.md`'s Rule as they appear. Amended 2026-11-23; see Decision Log.

Rationale: the logged-flakes half is complete within the proposal's problem. The signalling tests are an addition the
user chose. See below. Every other option is an addition with no logged failure behind it. The CPU-share half of "same
mechanisms elsewhere" names nothing: no other test uses
`usage`, `busyShare`, or `letTimePass`. Its `waitUntilExit` sites run on test threads rather than dispatch workers, and
none has failed. The real-time wait audit targets a different mechanism, sleeps that stand in for events. The fixture's
neighbors share the fixture's suspected cause, so they are the strongest candidate if a sighting names one of them.

The neighbors that signal are a different failure, not a flake. Each one checks `isRunning`, then signals the process
id. Once the helper is reaped, that id is free for reuse. So a test can kill an unrelated process of the same user. That
needs no logged sighting to matter. For a helper the test spawns, only the fixture's handle closes it. See
`spec/bugs/20261122-declared-file-watchdog-may-signal-reused-pid.md`. `PresentationTests` and `SenderWatcherTests`
spawn their own processes in `WindowKitTests`, so the fixture moves to `ScriptTestSupport`, which both test targets
already import. The same race sits in tests that signal a process something else reaps. Those are in the open
question below.

### How the closed-tab tests get their sample

- **Supply a busy sample end to end.** The closed-tab tests pass a sample through `policy.process.sample` that reads as
  busy. They keep the real signal and the real process exit. `ClosedProcessWatch`'s decision is already pinned by its
  own tests with supplied samples. Leaves undone: the live-sample test, which reads real CPU use by design.
- **Make the live window load-independent.** `letTimePass` stops spinning on the main thread, and the test fires only
  once its own sample reads busy. Every test keeps live samples. Leaves undone: a runner loaded by other processes can
  still starve the page.
- **Both.** Closed-tab tests supply their sample, and the one live-sample test waits until it reads busy. Leaves undone:
  the live-sample test can still be starved by outside load, as in the option above.
- **Derived samples plus a units bracket.** The closed-tab tests wrap the live sampler. It keeps the live reading's start
  time, its nil for a gone process, and its time taken, and replaces only the processor time: equal to the elapsed time
  for busy, frozen for idle. The live-sample test proves its units against independent readers instead of a timed
  window. Leaves undone: no test shows that a real spinning page reads busy under real scheduling.

Whichever option wins, `testClosingAnIdlePopUpSignalsNothing` keeps an idle sample, live or supplied.

Decision: derived samples plus a units bracket. The closed-tab tests that need a spinning page use a sampler wrapped
around the live one, which replaces only the processor time, and they drop `letTimePass`.
`testClosingAnIdlePopUpSignalsNothing` keeps its live sample, since load cannot make an idle page read busy. The
live-sample test keeps its idle side live. Its busy side becomes a bracket: an independent reading of the test's own
processor time and uptime before and after `WebContentProcess.usage(getpid())`, with the middle reading between them.

Rationale: it is the only option in which every check is independent of load. The watch averages over the whole span
from close to fire, so a test that waits for its own window to read busy does not bound that average, and a starved
page still fails. Sampling the live test again until it reads busy is a retry, which `spec/flaky-tests.md`'s Rule bans,
and a missed conversion then fails only at a deadline that cannot tell it from starvation. Supplying a busy sample alone
leaves the live-sample test exposed to the same load. A derived sample keeps the real process identity, the real nil for
a gone process, the real signal, and the real exit. It also makes the no-signal tests reach the live-tab check, which a
starved sample today lets them skip.

Dissent left standing: the option drops the live-sample test's claim that a real spinning page reads at least
`busyShare`. That reads as the weaker assertion `spec/flaky-tests.md`'s Rule bans. Answer: the regression the test names
is a units error, about 41 times off. The timed window caught a single wrong field too, but only when the runner gave the
page enough of a core. The bracket catches it in either field, or in both with their ratio intact, on every run. The
claim dropped is the part that depended on the runner's load. M1's measurement covers what it told us about the
product.

### How a test signals a process it does not reap

The fixture closes the race because it is its helper's only reaper. These tests signal a process that something else
reaps, so no test handle can hold the reap:

- **Reaped by other code in the test process.** `ExecPaneTests.swift:815` probes the driver with `kill(pid, 0)`, then
  sends SIGKILL. The product's exec transport spawns the driver in the test process and reaps it. Its reaped-flag
  signal is private, and the channel exposes only the pid. `ExecDriverChannelTests`' pause test sends the same driver
  SIGSTOP and then SIGCONT by pid. libghostty spawns `login(1)` as a child of the test process, and reaps it itself.
- **Reaped by launchd after a reparent.** `ExecDriverChannelTests.swift:451` kills the driver's background child, whose
  pid the driver writes to a file. `TerminalSessionIntegrationTests.swift:93`, `:756`, and `:762` kill the tree under
  `login`: the shell and its `sleep`, which launchd adopts once `login` exits on SIGHUP. `tearDown` and the defer at
  `:755` also kill `login` itself after `close()` returned. libghostty has reaped it by then, so that SIGKILL goes to a
  freed pid on every run.
- **WebKit content processes.** `WebContent.kill` in `BrowserRecoveryTests` and `MarkdownRig.swift:172` signal the pid
  that `_webProcessIdentifier` names. The `if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) }` defers in
  `BrowserRecoveryTests` and `BrowserHungProcessTests` check, then kill. The `policy(_:log:sample:)` helper in
  `BrowserHungProcessTests` passes the product's chosen pid to a real `kill`.

Making the test the parent does not help. It already is the parent of the driver and of `login`, but other code in the
same process holds the reap. macOS has no subreaper, so the test cannot take the reap of reparented or WebKit
processes either.

Each option is only as good as the moment the test learns the pid. Each site checks what it learned then. The
grandchild's parent is the driver. The terminal tree and its identities are read in one pass, before `close()`. A
WebContent pid's path carries `com.apple.WebKit.WebContent`, as `MarkdownRig.swift:166` already checks. The driver's
pid is read only while the channel is connected. The injected `signal` closure in `BrowserHungProcessTests` looks up
the identity the test learned, and refuses a pid it has none for.

- **An audit-token sender.** When the test learns a pid, it reads the process's audit token through
  `task_name_for_pid` and `task_info(TASK_AUDIT_TOKEN)`. Every later signal goes through
  `proc_signal_with_audittoken` (`libproc.h:132`). The kernel signals only the process whose pid version matches the
  token. It returns ESRCH for any other process, a zombie included. Design-critic probes on 2026-11-23 confirmed that
  for a child and for a reparented `sleep`. A token read for launchd, which runs as root, failed. Where no token can be
  read, the sender falls back to the identity check below. Each site states which path it expects, and fails the test
  when it gets the other. Leaves undone: a site on the fallback keeps that option's window. `login` is setuid root and
  likely refuses a token. WebContent may too, though it runs as the user. Neither was tested. The call has no
  documentation beyond its header. An OS release that drops it fails at link time. The decision reads the token fresh
  at each signal instead. A token read at learn time goes stale on exec. See the Decision Log for 2026-11-23.
- **An identity-checked sender.** The test records the pid and its start time to the microsecond, from
  `sysctl(KERN_PROC_PID)`'s `p_starttime`. `proc_pidinfo` refuses `login`. `ProcessInspection.startTime` keeps seconds
  only, so `ProcessInspection` gains a microsecond reader. The sender reads the start time again right before the
  signal, and signals only when it matches. Leaves undone: a reuse between that read and the signal. macOS hands out
  pids in order, so that needs about 99,900 pid allocations inside the window.
- **An exit watch.** The test registers a kqueue `EVFILT_PROC` `NOTE_EXIT` filter when it learns the pid. The sender
  signals only when no exit event has arrived. Leaves undone: the same window as the identity check, between the event
  check and the signal. It gains nothing over that option, and adds a kqueue per process.
- **Stop signalling.** Each site that already waits for the process to end fails the test instead of killing it.
  Leaves undone: a failed test leaves its process running. That breaks the terminal tests' rule that no test leaves an
  orphan, and the browser tests' cleanup of a page that keeps spinning.
- **Signal through the owner.** The product and libghostty gain a call that signals under their reaper's lock. Leaves
  undone: WebKit content processes and reparented processes have no owner in reach. It adds public product calls whose
  only users are tests, which `practices/testing.md` rules out.

`HelperProcess.kill`, used in `HelperClientTests`, already signals under its reaper's lock, so it needs nothing.
`ProcessInspectionTests` signals a child before its own `waitpid`, so it needs nothing either.
`RemoteClientWatcherTests` signals `sh` before its own `waitpid`, so that signal needs nothing. Its client is below.

The product's `WebContentProcess.kill` checks a pid's path, then signals it. ScriptHost's `ProcessReaper`
(`ScriptRepl.swift:58-73`) checks a `ProcessIdentity` whose start time has one-second resolution, then sends
`Darwin.kill`. Each is the same check-then-signal window in production code.

`RemoteClientWatcherTests.swift:255` spawns `sh`, which forks a 30 s client. `tearDown` kills only `sh`, so the client
outlives the test for up to 30 s. At `tearDown` the client is still `sh`'s child, since `sh` waits for it.

Decision: a site records a process's pid and its start time to the microsecond when it learns the pid. Right before
each signal, the guarded call reads a fresh audit token for the pid. It then reads the start time again. When the
start time matches, it signals by that token. A process that exec'd before the signal keeps its pid and start time,
so it is still reached.

When no token can be read, the call confirms the start time and then signals by pid. A token signal that returns
ESRCH is retried with a fresh token while the start time still matches a live record, up to three tries in all. The
call never signals by pid after ESRCH, so a retry that reads no token signals nothing. When the start time no longer
matches, it reports the process gone. After three tries it reports the process unreached, never gone.

`ProcessInspection` makes this one public call. It takes a pid, a microsecond start time, and a signal number. It
reports which path it took, or that the process is gone, unreached, or refused. It refuses a pid of 1 or below and
the caller's own pid, and signals nothing for them. It also gains a public microsecond start-time reader, which rejects
a zombie as the existing record reader does. The token stays inside the call as Darwin's `audit_token_t`. So
`ProcessInspection` keeps no dependencies. `FileRouting`'s `AuditToken` is unchanged. The token signal answers
EINVAL for signal 0. So a signal 0 probe through the call reports unreached with a token, and without one the pid
path sends it. Signal 0 probes stay outside the call.

Callers handle each result. The product's two kills treat gone as done, and log unreached and refused as errors.
`WebContentProcess.kill` returns false for gone, unreached, and refused. The test sender accepts gone, and fails the
test on unreached or refused.

A new test-support target, `ProcessTestSupport`, depends only on `ProcessInspection`. It holds the per-site sender,
and each site states which path it expects. It also holds the reader that tells whether a process is stopped.
`WebContentProcess` and the REPL channel record the microsecond identity. Their kills go through the same call.
`WebContentProcess.kill` keeps its path check before it. With no token, it still signals, so a hung page is still
ended. `RemoteClientWatcherTests` spawns `sh` in its own process group, and sends `killpg` before its own `waitpid`.
Amended 2026-11-25; see Decision Log.

Rationale: the token is the only option that closes the window outright, for every target that gives one. The token is
read before the start time. So when the start time still matches, the token names the recorded process, or that
process after an exec. When the pid moved on in between, the start time differs, or the token gets ESRCH. Either way
no other process is signalled. A token kept from the moment the site learned the pid would go stale on exec. A REPL
helper that execs would then outlive its pane, which today's identity check prevents. An exec inside the call's own
window also stales the token. The retry covers that, and it still never signals by pid. The identity check alone
narrows the window but leaves it. The exit watch gains nothing over the identity check. Stopping the signals leaves
orphans. Signalling through the owner needs product calls only tests use. It still cannot reach WebKit or reparented
processes. The fallback keeps the identity check's window only where the system refuses a token. A site that lands on
the wrong path fails its test, so a change in what the system allows shows up at once.

`ProcessInspection` serves every site and the product. A test-only home would need four more test targets to link
ScriptHost, and the product could not import it. The expected-path rule is test policy, so it stays in a test target.
The product's two kills have the same race as the tests, and the same call closes it there. A stale pid either fails
the path check, or fails the start-time match. No caller handles a token, so the package needs no new token type. The
group signal closes the `RemoteClientWatcherTests` window too. The unreaped `sh` holds the group id, so no other
process can take it.

Leaves undone: `login`, and WebContent if it refuses a token, keep the identity check's window, between the start-time
read and the signal by pid. M3 and M4 record which path each site took. A process that execs three times inside the
call's window is reported unreached, not signalled. The call has no documentation beyond `libproc.h`. An OS release
that drops it fails at link time, not silently.

## Design Decisions (Open)

None.

## Risks

- **A supplied sample hides a broken live reading** — likelihood: low, impact: medium.
  Mitigation: the live-sample test brackets the live reading against independent readers of processor time and uptime,
  so a reader in the wrong units still fails a test. The idle pop-up test keeps a live sample of a closed tab.
- **The closed process reads idle in the product too** — likelihood: low, impact: medium.
  The cause of the logged failure is not confirmed. WebKit may lower a content process's priority once it has no view.
  If so, a spinning closed tab can read under `busyShare` on a loaded machine and the product never ends it. Derived
  samples then hide that from CI. The likelihood is rated on the test-side explanation, a 0.3 s window shared with a
  main thread that spins, which is the stronger one. Mitigation: M1 measures the share of a real closed spinning tab
  under load and idle before the change, and a reading under `busyShare` in either run, or a priority drop after the
  close, goes to the user.
- **A spawned helper inherits the test process's signal state** — likelihood: medium, impact: medium.
  `posix_spawn` keeps ignored signals and the spawning thread's mask, where Foundation resets them. A REPL test ignores
  SIGPIPE for the whole test process, so helpers spawned after it would behave by test order. Mitigation: M2 starts the
  helper with every signal at its default and an empty mask, as the exec driver's transport does.
- **A group-wide signal weakens the controller signal tests** — likelihood: low, impact: medium.
  The exec driver's transport spawns into its own process group and signals it with `killpg`. A fixture that copies it
  would let `ControllerRunTests`' signal-relay tests pass for a command that forks and never relays SIGINT. Mitigation:
  M2 checks that the handle signals the helper's own process, never its group.
- **The audit-token call changes or goes away** — likelihood: low, impact: medium.
  `proc_signal_with_audittoken` has no documentation beyond `libproc.h`. A release could drop it, or refuse tokens for
  processes it allows today. Mitigation: a dropped call fails at link time. A refused token sends a site to the
  fallback, and each site fails its test when it gets a path it did not expect. With no token, the product's two kills
  confirm the microsecond start time and signal by pid.
- **WebContent refuses a token, and the product silently signals by pid** — likelihood: low, impact: low.
  The product then keeps a window between the start-time read and the signal, and no user sees a difference.
  Mitigation: a BrowserApplet test fails when a real view's content process gives no token. The product logs each
  kill that takes the pid path.
- **A new wait mechanism misses an exit the old one saw** — likelihood: low, impact: low.
  Mitigation: the fixture's change is proven against a helper that exits at once and one that exits after a delay.

## Milestones

### M1: The browser hung-process tests

**Status:** DONE

- The closed-tab tests pass on a runner whose cores are all busy with other work
- The live-sample test fails when either time field of the live reading is in the wrong units. Its bracket allows the
  difference between independent readers, set from a recorded measurement and far below a 41-fold error. The uptime side
  uses a reader other than `CLOCK_UPTIME_RAW`, which the product uses
- The derived busy sample's time taken always moves forward between the close and the fire, so an equal reading fails
  loudly instead of skipping the signal
- Before the change, a run of `testClosingASpinningTabEndsItsProcessWhenTheBoundRunsOut` with one busy loop per core,
  and one on an idle machine, log the watch's share and the closed process's scheduling state at the close and at the
  fire: its priority from `proc_pidinfo` and whether Darwin runs it in the background. The
  flake entry records both. A share under `busyShare` in either run, or a priority that drops after the close, goes to
  the user as a product finding before the change lands
- A supplied busy sample reaches the live-tab check: the busy-opener test and the first close of the last-live-tab test
  fail when that check is removed
- `testClosingAnIdlePopUpSignalsNothing`'s doc comment says that the idle guard and the live-tab check each stop the
  signal alone, since its opener shares the process
- `testClosingAnIdlePopUpSignalsNothing` still sees an idle page and signals nothing, and its wait ends on a bound,
  never on a busy reading
- The closed-tab test's entry in `spec/flaky-tests.md` records the change, says the test pins the fix and not the bug,
  and stays under Potential until it meets the closing rule in the `spec/flaky-tests.md` Rule section
- Production's `busyShare`, bound, and time sources are unchanged

**As built:**

- The before-change measurement found no product finding. Every run read the closed page at 0.966 of a core or more.
  That held over the test's 0.3 s window and over the product's 10 s bound, idle and with a busy loop per core. The
  closed process kept its priority and its Darwin role from the close to the fire. The numbers are in the closed-tab
  test's entry in `spec/flaky-tests.md`. The busy loops ran at default priority, below the page's, so none could
  starve it. The CI failure did not reproduce, so its cause stays unconfirmed, and the test pins the fix, not the bug.
- The derived busy sample checks each reading of a process against the one before it. That covers every watch a test
  arms, including the one the harness's teardown arms. A sample made to read the same time every time failed the four
  derived-sample tests with the sampler's message. With the check also removed, the busy-opener test passed without
  reaching the live-tab check.
- Removing the live-tab check failed the busy-opener test and the first close of the last-live-tab test. The idle
  pop-up test still passed, as its doc comment says.
- The bracket reads the test's own processor time from the POSIX process CPU clock, and its uptime from Foundation's
  system uptime. Its allowance is 10 µs. Over 100,000 measured brackets, the CPU clock trailed the usage reader by at
  most 1.5 µs, and the uptime reader never fell outside. The live-sample test failed with the processor time left in
  Mach ticks, with it converted twice, with the time taken in Mach ticks, and with both in Mach ticks. It is now
  `testTheLiveSampleIsInNanosecondsAndReadsAnIdlePageAsIdle`, since it no longer reads a spinning page.
- `testClosingAnIdlePopUpSignalsNothing` also checks that the watch's own live readings, at the close and at the fire,
  read under the share. They read under 0.006 in each of the four runs that printed them, idle and loaded. Its wait
  stays a fixed 0.3 s.
- After the change, the class passed idle, with 14 and with 42 busy loops in the test process, and with 14 busy
  processes. The closed-tab test went from 0.73 s to 0.14 s. Production code is unchanged.

### M2: The script fixture's helper exit

**Status:** DONE

Amended 2026-11-25; see Decision Log.

- `ScriptFixtures.finish` returns once its helper exits, without `waitUntilExit`, including for a helper that exited
  before `finish` was called
- Callers that observe a helper's exit, as `onExit` callers do today, still see it
- Every caller of `start` and `finish` runs its helper through the fixture's exit path. That includes every caller that
  builds its own `Process` and hands it to `finish` today, such as `ScriptRunCommandTests.runRaw`,
  `ScriptLintCommandTests`, `ScriptOpenRunTests`, `ScriptAskRunTests`, `ControllerRunTests`, `ControllerConsentTests`,
  `CommandHelperSandboxTests`, `DeclaredFileRunTests.run`, and the fake-app run in `DeclaredFileProtocolTests`. Their own
  `isRunning` watchdogs go with it
- The spawned helper inherits only its standard input, output, and error, so a write end leaked into one helper never
  holds another fixture's pipe open. It still gets the caller's input pipe, environment, and working directory
- `onExit` runs once, from the thread that reaps the helper
- A signal goes out only while the reaped flag, read under the same lock the reaper sets it under, says the helper has
  not been reaped. Each wait retries on `EINTR`
- The regression test says that it pins the fix and not the bug, since no test reproduced Foundation missing an exit
- A test can still tell a helper's exit from its death by a signal
- The watchdog never signals a helper that has been reaped. The reaper waits with `waitid` and `WNOWAIT`, sets the reaped
  flag under the lock, and only then reaps with `waitpid`. Darwin's `waitid` also reports a stopped child to a wait for
  exits alone. The reaper takes that report with a wait for stops alone, and waits again
- Callers of `start` and `finish` signal a helper through the fixture's handle, never with a raw `kill` on its process
  id
- The tests among those callers that send SIGINT, such as the Ctrl-C tests in `ScriptLimitsTests`,
  `ScriptAskScriptTests`, and `ScriptAskRunTests`, still deliver it and still see the helper's exit
- The fixture spawns any executable with any argument list and environment, and `start` is a thin wrapper on it
- The spawn takes any file handle for each standard stream: a pipe the caller owns, a pty end, or the null device
- The handle reports whether the helper has exited, and its status, without waiting. It sends any signal number
- The handle signals the helper's own process, never its process group
- The handle sends with `signal(_:)`, and has no method named `kill`, `terminate`, or `interrupt`
- A helper stopped by SIGSTOP still reads as running, and SIGCONT and SIGKILL still reach it
- The 60 s and 70 s hang guard belongs to `start`. The generic spawn takes each caller's own deadline and signal
- The helper starts with every signal at its default and an empty signal mask, whatever the test process has set
- The fixture marks its pipe ends close-on-exec right after creating them and before it spawns or returns, as the exec
  driver's transport does, so no other spawner in the test process inherits them.
  `finish` states what it does when the helper is reaped but a pipe stays open
- A wait that returns `ECHILD` marks the helper reaped and fails the test with an error that names another reaper. It
  never reports a made-up status
- The handle reports a normal exit and a death by signal apart, as `terminationReason` does today
- The `ScriptFixtures.finish` entry in `spec/flaky-tests.md` records the change, says which of its sightings it
  explains, and stays under Potential until it meets the closing rule in the `spec/flaky-tests.md` Rule section

**As built:**

- The handle spawns any executable with any argument list, environment, and folder. Each standard stream is the null
  device, a file handle the caller owns, or a pipe the handle captures and reads from the spawn on. Each caller names its
  own deadlines. `start` keeps the 60 s SIGTERM and 70 s SIGKILL. The handle sends with `signal(_:)`, which reports
  sent, refused because the helper was reaped, or the errno `kill` returned. It reports whether the helper runs, its
  exit without waiting, and a wait for the exit. An exit and a death by signal are separate cases. The names and the
  stream and result types are run best guesses. See the Decision Log for 2026-11-25.
- `finish` now throws. A wait that finds no child marks the helper reaped and throws an error that names another
  reaper. The run's result keeps `status`, the exit status or the signal number as Foundation read it, and adds the
  exit case that tells the two apart. When a helper is reaped while a process it started holds a captured pipe open,
  `finish` keeps what the pipe held at the reap and returns.
- The stopped-helper test caught Darwin's `waitid` reporting a stop to the reaper's wait for exits. The reaper now takes
  that report and waits again, and the milestone's reaper bullet is amended. See the Decision Log for 2026-11-25. The
  exec driver's transport had the same gap. "Keep a stopped exec driver from reading as exited" fixes it. The
  product's `HelperProcess` uses the same wait, but it kills its helper before it waits, so a stop never reads as an
  exit there. It needed no change.
- Three moved callers had no hang guard: the shipped command's `open` run, the deleted-folder `open` run, and the
  fake-app run. Each now has a 60 s SIGKILL deadline. See the Decision Log for 2026-11-25.
- `HelperHandleTests` proves the bullets, and its regression test says it pins the fix, not the bug. Mutations each
  failed a test, and each was restored: signalling after the reap, waiting without `WNOWAIT`, a `waitid` that gives up
  on EINTR, pipe ends left inheritable, no close-on-exec default for the spawn, no signal default, no empty mask, no
  stop-report wait, a reader that waits for a held pipe's end, reading that starts only at `finish`, and a signal to the
  helper's group. Dropping the lock in `signal` passed the plain tests and drew a Thread Sanitizer data race report on
  the reaped flag. The unmutated fixture runs clean under the sanitizer.
- The EINTR proof interrupts the reaper's `waitid` with a thread-directed SIGUSR2. The `waitpid` retry has no proof,
  since no test can catch the reaper inside it.
- `ScriptHostTests` passed 358 tests, with 3 skipped, and the 3 skipped shipped-command tests passed under
  `make test-helper-sandbox`. The SIGINT tests still deliver the signal and see the exit.

### M3: Every test signal goes through a guarded sender

**Status:** DONE

Amended 2026-11-25 and 2026-11-27; see Decision Log.

Starts after M2 and M4. It moves sites onto M2's handle, and onto M4's guarded call.

No package test signals a process by an id that the process may no longer hold.

- These sites spawn through the fixture and signal only through its handle:
  - `DeclaredFileRunTests.start`, its watchdog, and the teardowns of the tests that use it
  - `ReplSupport`'s session, on pipes and on a pty, with its watchdogs, teardown, and interrupt
  - `ScriptReplTests`' own helper run, and its kill of a REPL session
  - `ControllerRunTests`' own `start`, its two inline runs, and the stand-in instance in its launch-cleanup test
  - `ScriptReplGrantTests`' `/bin/sleep` stand-ins for a second session
  - `ScriptGrantTests`' source session, and `SocketRelay.stop`
  - `ScriptReplLimitsTests`' teardown, its stop of a session, its SIGSTOP of a hung helper, and its reaper's kill
    closure
  - `ControllerConsentTests`' kills of an admitted run
  - `PresentationTests`' helper run and its watchdog
  - `SenderWatcherTests`' `/bin/sleep`
- `ControllerConsentTests.run` hands the test its handle before it waits. Each kill checks that the admitted pid equals
  that handle's pid, and fails the test otherwise
- The reaper's kill closure in `ScriptReplLimitsTests` finds the test's handle for the pid under a lock, and signals
  through it. A pid with no handle is recorded and not signalled
- `ReplProcess`'s interrupt is renamed to `sendInterrupt`, so the search below finds no `.interrupt()`. The test
  helper's `WebContent.kill` is renamed to `crash`, so the search finds no `kill(` on a content process
- The fixture lives in `ScriptTestSupport`, with a public API. The `start` wrapper stays in `ScriptHostTests`, since its
  scripts come from that target's bundle
- The sites in "How a test signals a process it does not reap" signal only through the sender in
  `ProcessTestSupport`, which depends only on `ProcessInspection`. That covers `BrowserRecoveryTests`' `WebContent`
  helper and its defers, the defers in `BrowserHungProcessTests`, `MarkdownRig`'s content-process kill, `ExecPaneTests`'
  driver kill, and `ExecDriverChannelTests`' grandchild kill and pause test
- The sender signals through `ProcessInspection`'s guarded signal call. Each site states whether it expects the token
  path or the pid path. A site fails the test when it gets the other
- The sender accepts gone. It fails the test on unreached or refused
- Each site checks the pid when it learns it. The grandchild's parent is the driver. Each terminal tree member's
  microsecond start time is read in one pass before `close()`, and its parent is the member before it. A WebContent
  pid's path carries `com.apple.WebKit.WebContent`. The driver's pid is read while its channel is connected
- The terminal teardowns signal `login` only through its recorded identity, so a `login` that `close()` already ended
  gets no signal
- The injected `signal` closure in `BrowserHungProcessTests` forwards the identity the product read to the sender, and
  records the pid. It signals nothing for an identity it was not given
- `ExecDriverChannelTests`' pause test sends its SIGSTOP and SIGCONT through the sender, and expects the token path.
  It records the driver's identity while the channel is connected
- The stopped-state reader lives in `ProcessTestSupport`, and `HelperHandleTests` and `ExecDriverChannelTests` drop
  their copies of `isStopped`. Reading whether the fixture's own helper is stopped is not a signal site
- `RemoteClientWatcherTests` spawns `sh` in its own process group. `tearDown` sends `killpg` before its own `waitpid`,
  so the client `sh` forks ends with it
- The As built block records which path each site took, and whether `login` gave a token
- No package test sends a signal with a raw `kill` on a process id, or with `Process.terminate` or `interrupt`
- Signal 0 probes are exempt. So is the relay's forked child, which its parent never reaps. So are tests that signal
  their own child before their own `waitpid`, and `HelperProcess.kill`, which signals under its reaper's lock. So is the
  `pthread_kill` in `HelperHandleTests`' EINTR test, which signals a thread of the test process and names no process id
- `ReplProcess` and every moved site expose the fixture's handle and no `Process`, so `.terminate()` on them does not
  compile
- A search of `Tests/` for `kill(`, `.terminate()`, and `.interrupt()` finds only the fixture, the sender, the
  exemptions above, the group signal in `RemoteClientWatcherTests`, and product kill calls under test that send
  through an injected sender
- Each moved site keeps its hang guard: a helper that never exits is still killed at that site's own deadline
- The tests that send SIGINT, SIGSTOP, or SIGCONT through a moved site, such as the Ctrl-C tests in `ScriptReplTests`
  and `ControllerRunTests`, still deliver it and still see the helper's exit
- The REPL session still gets its input pipe, and still reads its output as it arrives
- The As built block says that M3 pins the fix and not the bug, since no test can force a process id's reuse
- `spec/bugs/20261122-declared-file-watchdog-may-signal-reused-pid.md` is closed as fixed

**As built:**

- `HelperHandle` and its stream, result, and error types moved to `ScriptTestSupport` with a public API.
  `HelperHandleTests` stayed in `ScriptHostTests`. `ProcessTestSupport` is new and depends only on `ProcessInspection`.
  It holds `ProcessRecord`, a pid with its microsecond start time, `ProcessSender.signal` and `ProcessSender.send`, and
  `ProcessSender.isStopped`. `signal` reports whether a signal went out. `send` returns what the guarded call reported,
  for a test that stands in for a product's signal seam. Both fail the test on unreached, refused, or the other path,
  and accept gone. The names are run best guesses. See the Decision Log for 2026-11-27.
- Every `ScriptHostTests` site that spawned a helper now spawns it through the handle. `ReplProcess`, the source session
  in `ScriptGrantTests`, `SocketRelay`, the `/bin/sleep` stand-ins, and `ControllerRunTests`' `start` and two inline
  runs hold or expose a `HelperHandle`, and none exposes a `Process`. `DeclaredFileRunTests.start`, `ScriptReplTests`'
  probe run, and `PresentationTests.run` use the handle's own deadlines in place of their watchdogs.
  `ControllerConsentTests` keeps each handle `run` spawned, and `endRun` ends an admitted run only when its pid is one
  of them. `ScriptReplLimitsTests`' reaper closure finds the handle by pid under a lock and records, without signalling,
  a pid it has no handle for. `ReplProcess.interrupt` is now `sendInterrupt`.
- A handle given a pipe the caller reads keeps no hold on that pipe. A `LineCollector` whose `Pipe` was released at the
  end of `start` let the read end close, and the helper died of SIGPIPE. `LineCollector` now takes the owner to retain.
- Sites that signal a process something else reaps went through the sender. They took these paths:
  - `login`: the pid path. A test sends SIGCONT to each live member of a session's tree through the path its teardown
    expects, and `login` gave no token. Every other member of the tree took the token path.
  - A WebContent process: the token path, in the tests that end a real one. `BrowserHungProcessTests`' injected signal
    closure forwards the identity the product read to `ProcessSender.send`, and refuses a pid no test recorded.
  - The exec driver: the token path, in the pause test, which signals a live driver. `ExecPaneTests` and the grandchild
    test expect the token path too, and a process already gone is accepted.
- The terminal teardowns record each tree member's start time in one pass before `close()`. A child counts only while
  its parent is the member that listed it. `login` has been reaped by the time the teardown signals, so its record reads
  gone and gets no signal.
- `RemoteClientWatcherTests` spawns each child in its own process group and ends it with `killpg` before its own
  `waitpid`, which also ends the client `sh` forks.
- The search of `Tests/` for `kill(`, `.terminate()`, and `.interrupt()` finds the handle's own signal, the group
  signal, the product kills under test, the signal 0 probes, `pthread_kill`, `HelperProcess.kill`, the signals to a
  child before its own `waitpid` in `ProcessInspectionTests`, `ProcessSignalTests`, and `BrowserHungProcessTests`, and
  one raw SIGKILL in `ScriptBindingTests`, to the relay's forked child. Its parent never reaps it, so no handle holds
  it.
- The package suite passed: 3296 tests, 10 skipped, 0 failures, in 281 s. M3 pins the fix and not the bug, since no test
  can force a process id's reuse. No mutation of the sender was run, so a wrong-path result is shown only by the passing
  path checks above.

### M4: The product's kills signal by audit token

**Status:** DONE

Needs nothing from M1 to M3. It lands before M3, since M3's sender wraps its guarded call.

- `ProcessInspection` gains a public microsecond start-time reader, and one public guarded signal call. The call takes
  a pid, a microsecond start time, and a signal number. It reads a fresh audit token, reads the start time again, and
  signals by the token when the start time matches. With no token, it confirms the start time and signals by pid. It
  reports which path it took, or that the process is gone, unreached, or refused
- A token signal that returns ESRCH is retried with a fresh token while the start time still matches a live record,
  up to three tries in all. It never signals by pid after ESRCH. After three tries the call reports unreached, never
  gone
- A retry that reads no token signals nothing. It reports unreached while the start time matches, or gone when it
  does not
- The call refuses a pid of 1 or below and the caller's own pid, signals nothing, and reports refused. A test passes
  pid 0, pid 1, and `getpid()`, and sees refused each time
- The microsecond reader goes through the existing record reader, so a zombie reports gone, not the pid path. A test
  spawns a child, leaves it unwaited after it exits, and sees gone
- The token read releases its task name port on every path. The token stays inside `ProcessInspection` as
  `audit_token_t`. `FileRouting`'s `AuditToken` is unchanged
- `ProcessInspectionTests` signals a live child through the call with its recorded start time, and the child ends by
  the token path. A start time one microsecond off leaves the child alive. A reaped child reports gone
- The exec test waits until the child's executable path shows the new image, then signals it through the call with
  the start time recorded before the exec. The child ends by the token path
- Through `@testable import`, an internal token one pid version off returns ESRCH, read as an errno-style return, and
  the child stays alive
- The call's internal form takes a token reader. A test's reader first returns a token read before the child exec'd,
  then reads live tokens. The call retries, and the exec'd process is ended
- `Package.swift` lists `BrowserApplet`'s new `ProcessInspection` dependency. The comment on `ProcessInspection` names
  every target that uses it
- `WebContentProcess` reads the microsecond identity through an injected reader beside `sample`. Its `Signal` seam
  receives the identity the product recorded. Nothing signals a stored pid alone
- A test whose reader returns one identity at the close and another at the fire sees the close's identity at the
  `Signal` seam. The tests with a made-up pid, such as 4242, still reach the seam through their injected reader
- `WebContentProcess.kill` keeps its path check, then signals through the guarded call. It returns false for gone,
  unreached, and refused
- A product test injects `pathOf` to name a content process, with the live guarded call. `kill` on a live child whose
  recorded start time is one microsecond off returns false, and the child stays alive. The matching identity ends it
- A BrowserApplet test fails when a real view's content process gives no token
- `WebContentProcess.kill` and the reaper log each kill that takes the pid path, and log an error for unreached and
  refused. They never log for a process the call reports gone. A test checks the log through
  `OSLogStore(scope: .currentProcessIdentifier)`
- `killUnused` compares live views by pid, and reads no token
- The REPL channel records the helper's microsecond start time beside its `ProcessIdentity`. `ProcessReaper.kill`
  receives that identity, and `.live` sends through the guarded call. `ProcessIdentity`'s fields, equality, hashing,
  and `folderName` are unchanged
- A ScriptHost test spawns a child, records it, and has it exec. The reaper still ends it. A recorded start time one
  microsecond off leaves the child alive
- Production's `busyShare`, bound, and time sources are unchanged
- The As built block records which path WebContent and the REPL helper took. It says M4 pins the fix and not the bug,
  since no test can force a process id's reuse

**As built:**

- The guarded call and the microsecond reader shipped as the bullets give them. The token read also rejects a token
  that names another pid. A failure other than ESRCH reports unreached on either path. The names are run best guesses,
  in the Decision Log entry for M4's mechanisms.
- The token signal answers EINVAL for signal 0. So a signal 0 probe with a token reports unreached, and without one
  the pid path sends it. The tests probe with SIGCONT instead, and the decision now says so.
- The browser reads the content process's identity at the close, and arms no bound when it reads none. The kill at
  the fire names that identity. The hang path reads it from the live view right before its kill. The kill returns
  true for the token and pid paths only.
- The REPL channel takes the seconds and the microseconds from one reading of the helper, so its `ProcessIdentity`
  is unchanged. A reaper whose peer is the test process now gets refused, instead of sending SIGKILL to itself.
- Both WebContent and the REPL helper took the token path. The four BrowserApplet tests that end a real content
  process assert it, so a macOS that stops giving WebContent a token fails them. A ScriptHost test ends a real REPL
  helper through the guarded call and sees the token path.
- The log checks read `OSLogStore(scope: .currentProcessIdentifier)` with a made-up pid per result, through an
  injected signal. Each takes about 1 to 3 s, which is the store's own read.
- Mutations each failed a test, and each was restored: a start time compared to the second, a pid fallback after
  ESRCH, no task name port release, no refusal, a microsecond reader that skips the zombie check, two tries, one try,
  `kill` without its path check, a watch that reads the identity at the fire, a browser seam and a live reaper that
  signal the stored pid alone, and a missing pid-path log line in each kill.
- M4 pins the fix and not the bug, since no test can force a process id's reuse. `busyShare`, the bound, and the time
  sources are unchanged.

## Decision Log

- 2026-11-21: Filed during a landing run in which two package-test failures cost CI reruns. The user asked whether
  this flakiness could be fixed for the future.
- 2026-11-21: Re-scoped from "inject clocks into timing-sensitive package tests". A design review found neither
  motivating test was a clock problem. The exec stall test was already fixed, and the browser test already injects its
  bound. The user chose to re-scope around the actual flake mechanisms.
- 2026-11-22: Review start: 2 milestones, 2 settled decisions, 2 risks, no `**Live after:**` lines or row gates, and no
  out-of-scope statements beyond the audit question's addition label. The user asked for an autonomous review of the
  four open questions. The proposal stood at the commit "Route UTERM-046's final review checks into its milestones".
- 2026-11-22: The browser tests keep polling for the content process to end. The poll already ends on the event, with
  a deadline, and no logged failure came from it. (autonomous)
- 2026-11-22: The script fixture spawns and reaps its own helper, and every caller of `start` and `finish` moves to the
  fixture's handle. It is the only option immune both to Foundation missing an exit and to another reaper, and the
  only one that keeps the watchdog off a freed process id. (autonomous)
- 2026-11-22: The audit covers the two logged flakes only. Every wider audit is an addition with no logged failure
  behind it. (autonomous)
- 2026-11-22: The closed-tab tests derive their sample from the live one, replacing only the processor time, and the
  live-sample test proves its units with a bracket against independent readers. Every check is then independent of load.
  The live claim that a real spinning page reads busy is dropped. (autonomous)
- 2026-11-22: Added the risk that a closed process reads idle in the product too, with a measurement in M1. (autonomous)
- 2026-11-22: The Summary now says the live-sample claim that a real spinning page reads busy gives way to a units
  check. M1's product measurement escalates a low share from the loaded run as well as the idle one. (autonomous)
- 2026-11-22: Added the risk that a spawned helper inherits the test process's signal state, mitigated in M2.
  (autonomous)
- 2026-11-22: M1's and M2's flaky-entry checks now close an entry by the closing rule in the `spec/flaky-tests.md` Rule
  section, the rule UTERM-045 sets for every entry, instead of an unstated count of CI runs. (autonomous)
- 2026-11-22: Review gate: kept all. Derived samples plus a units bracket stand, and the Summary keeps its reworded
  claim. No decision gets an ADR. Status set to accepted.
- 2026-11-22: Scheduled as UTERM-046 M1-M2 in queue.md.
- 2026-11-23: Added M3, which moves every `ScriptHostTests` site that signals its helper by process id onto the
  fixture's handle. This came from bug triage of `spec/bugs/20261122-declared-file-watchdog-may-signal-reused-pid.md`.
  The audit decision read "Decision: logged flakes only. New flakes go through `spec/flaky-tests.md`'s Rule as they
  appear." It now also covers the neighbors that signal. The fixture decision's "Leaves undone" listed
  `DeclaredFileRunTests.start`, `ReplSupport`, the `isRunning` polls in `ControllerRunTests`, and `ScriptReplTests`' own
  helper run. M3 now moves those. Why: a raw signal after a reap can kill an unrelated process, and that is a correctness
  risk, not a flake. The user chose this over adding only `DeclaredFileRunTests.start` to M2. (addition)
- 2026-11-23: A design-critic pass on M3 found it sound with caveats. Moving every signal onto the fixture's handle is
  the only option that closes the race. Corrections of fact: M3 named four sites, but its catch-all check forbade about
  twenty more raw signals in `ScriptHostTests`. M3 now lists every site. Leaves undone said the `ScriptGrantTests`
  source session never signals. Its teardown terminates it, so it moved to M3. The Summary and the audit rationale still
  described only the two flakes. Routed checks to M2 that M3's sites need: caller-owned streams, a pty, a non-blocking
  exit query, any signal number, signals to the process and not its group, and `start` owning its own hang guard.
  Moved the SIGINT check for M2's callers into M2. Added the risk that a group-wide signal weakens the controller signal
  tests. M3 now starts after M2, and exempts signal 0 probes and the relay's forked child.
- 2026-11-23: The user chose to specify the fixture's wider spawn in M2, over extending it in M3. M2 owns the fixture,
  and building it once keeps it from changing shape after M2 lands. This serves M3's addition. (addition)
- 2026-11-23: The user chose to add `PresentationTests`' watchdog to M3, over filing it as a bug. The fixture moves to
  a test-support target that `ScriptHostTests` and `WindowKitTests` both import. (addition)
- 2026-11-23: The user chose to have moved sites expose only the fixture's handle, so `.terminate()` on them does not
  compile, over a source search alone. The search still covers bare `kill` on a process id.
- 2026-11-23: Scheduled UTERM-046 M3 in queue.md, in the same row as M1-M2.
- 2026-11-23: A re-check pass on M2 and M3 did not converge. Corrections of fact: the audit decision said the
  signalling tests covered `ScriptHostTests` and `PresentationTests`, and M3's checks covered "both targets". All of
  `WindowKitTests` held more sites, and so did five other test targets. `ControllerConsentTests`' kill sites had no
  handle in reach, since `run` returns only after `finish`. `ScriptReplLimitsTests`' reaper closure runs off the main
  actor. M3's search would have hit the handle's own sender and `ReplProcess.interrupt`. M3 named an unnamed "second
  session". The fixture's target is `ScriptTestSupport`, which both test targets already import. Routed checks to M2:
  the handle's sender is `signal(_:)`, and a stopped helper still reads as running. Routed the handle hand-off, the
  reaper lookup, and the rename to M3.
- 2026-11-23: The user chose to close the race in every package test, over narrowing M3 to `ScriptHostTests` and
  `PresentationTests` and filing a bug for the rest. "Filing a bug while designing the proposal that would've fixed
  the bug is idiotic." The audit decision said "every test that signals a process it spawned by process id. That
  covers `ScriptHostTests` and the watchdog in `WindowKitTests`' `PresentationTests`." It now covers every package
  test that signals a process by its id. M3 adds `SenderWatcherTests`. The sites whose process the product,
  libghostty, or WebKit reaps open "How a test signals a process it does not reap". Status set to designing until it
  settles. (addition)
- 2026-11-23: A design-critic pass on "How a test signals a process it does not reap" added the audit-token sender.
  Corrections of fact: the question said "macOS has no process handle that a non-parent can hold, so no option closes
  the window". `proc_signal_with_audittoken` signals only the process a token names. The identity check said
  "start time, to the microsecond, from `proc_pidinfo`". `proc_pidinfo` refuses `login`, so it reads sysctl. The
  question said libghostty "spawns and reaps that shell". It spawns and reaps `login`, and the shell is reparented. The
  terminal teardowns kill `login`'s freed pid on every run, which the question did not say. Added the checks each site
  makes when it learns a pid, and the orphan `RemoteClientWatcherTests` leaves.
- 2026-11-23: The user chose the audit-token sender, with the identity check as its fallback where no token can be
  read. The user preferred it over the identity check alone, an exit watch, stopping the signals, and signalling
  through each owner. Routed its checks to M3, and added the risk that the call changes or goes away.
- 2026-11-23: The user chose to fix the product's `WebContentProcess.kill` here, over keeping production out. Amended
  "Production behavior does not change". It said "production code keeps its bounds, its time sources, and its
  `busyShare`", with no production change at all. The kill now signals by the content process's token, and keeps its
  path check when it reads none. The bounds, time sources, and `busyShare` stay as they were. (addition)
- 2026-11-23: The user chose to have `RemoteClientWatcherTests` end the client its `sh` forks, through the sender, over
  leaving the orphan. (addition)
- 2026-11-23: A final re-check pass did not converge. Corrections of fact: the decision put "one sender in
  `ScriptTestSupport`" behind every site. Five site targets do not import it, and the product cannot import a test
  target. The product's token path dropped `WebContentProcess.kill`'s rule that it "refuses what is not a content
  process". The product change sat in M3, a test milestone gated on M2. The rationale said the orphan "is a
  reparented process, which only this sender can end safely". At `tearDown` it is still `sh`'s child. The re-check
  also found ScriptHost's `ProcessReaper` sends `Darwin.kill` after a one-second identity check. Moved the product
  change into M4, which M3 now follows. Renamed "Production behavior does not change" to "Production keeps its rules",
  since its body allows a change. Added the risk that WebContent refuses a token. Routed the ESRCH, seam, port, and
  tree-parent checks.
- 2026-11-23: The user chose `ProcessInspection` for the token read, the token signal, and the microsecond start time.
  A new `ProcessTestSupport` target holds the per-site sender. The user preferred that over putting the sender in the
  product library too, and over keeping it in `ScriptTestSupport`. Amended "How a test signals a process it does not
  reap": it said "an audit-token sender in `ScriptTestSupport`". (addition)
- 2026-11-23: The user chose a process group and `killpg` for the `RemoteClientWatcherTests` client, over the token
  sender. The earlier recommendation of the sender rested on the false claim that the client was reparented. Amended
  the same decision: it said the test "ends the client its `sh` forks through the sender".
- 2026-11-23: The user chose to move ScriptHost's `ProcessReaper` onto the token signal in M4, over keeping it out.
  Amended "Production keeps its rules" to name it beside `WebContentProcess.kill`. (addition)
- 2026-11-23: Added M4 for the product's two kills. M3 follows it.
- 2026-11-23: A re-check of M4 found every change sound, with one design gap: the token's type. Corrections of fact:
  M4 said `ProcessReaper` "records a token with each `ProcessIdentity`". A stored token breaks that type's equality and
  its `folderName` round trip, so the token now rides beside it. The decision said `ProcessReaper` reads its own token.
  The REPL channel already holds the token the kernel gave its connection, so it records that one. M4 had
  `killUnused` read a token for every live view. Comparing pids gives the same outcome. "Five more test targets"
  is four, since `RemoteClientWatcherTests` no longer needs the sender. Routed checks to M4: the watch fires the token
  read at the close, `BrowserApplet`'s new dependency is listed, and M4 pins the fix and not the bug.
- 2026-11-23: The user chose to move the existing `AuditToken` from `FileRouting` into `ProcessInspection`, with
  `FileRouting` depending on `ProcessInspection`. The user preferred it over a second token type and over a raw
  `audit_token_t`. Amended "How a test signals a process it does not reap" to name the type. (addition)
- 2026-11-23: A re-check of the token type found the move feasible. It also found two REPL gaps. A token kept from
  admission goes stale when the helper execs, so the helper would outlive its pane, where today's identity check ends
  it. The listener admits no peer without a token, so the reaper's no-token fallback could never run. The watch check
  could not tell a token read at the close from one read at the fire. `ProcessReaper.kill`'s seam was unstated.
- 2026-11-23: The user chose a fresh token at every signal. There were three alternatives. One was a fresh token for
  the reaper only, which left the exec escape at the test sites. One kept the admission token and its exec escape. One
  was an identity fallback on ESRCH. Amended "How a test signals a process it does not reap". It said "When the test
  learns a pid, it reads the process's audit token", and the REPL channel's token was "the one the kernel gave its
  connection at admission". A site now records the pid and microsecond start time. The guarded call reads a fresh
  token, confirms the start time, and signals by the token. M3 and M4 are rewritten to match. The REPL fallback text
  is gone.
- 2026-11-23: The user chose to drop the `AuditToken` move, over keeping it. No caller of the guarded call handles a
  token, so the move served no current caller. Amended the same decision: it said "The calls take and return the
  existing `AuditToken`. It moves from `FileRouting` into `ProcessInspection`". The token stays inside
  `ProcessInspection` as `audit_token_t`.
- 2026-11-24: A re-check of the fresh-token design confirmed the ordering argument by probe. Exec keeps
  `p_starttime` to the microsecond and bumps the pid version. A zombie gives no token. Corrections of fact: the
  decision said "A token signal that returns ESRCH means the process is gone". An exec between the token read and the
  signal also gets ESRCH, while the process lives. It said "A process that execs keeps its pid and start time, so it is
  still reached". That holds only for an exec before the signal. The risks said the product "keeps its path check" and
  "today's window" with no token. With no token, it also checks the microsecond start time. Routed checks to M4: an
  injected identity reader for the watch tests, an exec test that waits for the new image, `@testable` for the
  internal token test, zombie rejection, refusal of pid 1 or below and the caller's own pid, and a log only for the pid
  path. Noted on the audit-token candidate that the decision reads the token fresh.
- 2026-11-24: The user chose to retry a token signal that gets ESRCH, while the start time still matches, up to three
  tries. The alternative was to report the process gone and record the gap. Amended "How a test signals a process it
  does not reap": it said "A token signal that returns ESRCH means the process is gone, and nothing more is sent". The
  call never signals by pid after ESRCH. After three tries it reports the process unreached.
- 2026-11-24: The re-check of the retry converged. The retry reaches only the recorded process or its exec'd self, and
  sends no signal twice, since the kernel's version check fails before delivery. Routed checks to M3 and M4: a retry
  that reads no token signals nothing, each caller's handling of gone and unreached, zombie and refusal tests, the
  internal token reader that stales a token inside the call, the ESRCH test that the child stays alive, and how the
  log is checked. "Up to three tries" now says "in all".
- 2026-11-24: The user chose a separate refused result for a pid of 1 or below or the caller's own pid, over reporting
  gone with a log line. Amended "How a test signals a process it does not reap": it said the call "refuses a pid of 1
  or below and the caller's own pid", with M4 saying it "reports gone". The product logs refused as an error, and the
  test sender fails the test on it.
- 2026-11-24: Review gate: kept all. The last re-check converged, and no decision is open. No decision gets an ADR.
  Status set to accepted.
- 2026-11-25: M1's mechanisms were chosen in the work-queue run. The bracket's independent readers are the POSIX
  process CPU clock and Foundation's system uptime. Its 10 µs allowance comes from a measurement. The derived busy
  sample's forward check covers every reading of a process, not only the close and the fire. The idle pop-up test
  checks that the watch's live readings read idle, which is how "still sees an idle page" is checked. The live-sample
  test was renamed, since it no longer reads a spinning page. The before-change measurement added runs with separate
  busy processes and runs over the product's 10 s bound. Busy loops in the test process left the page 98% of a core
  even at user-interactive QoS. (run best guess)
- 2026-11-25: M2's mechanisms were chosen in the work-queue run. The handle is `HelperHandle`, with
  `signal(_:)`, `isRunning`, `exitStatus()`, `waitForExit()`, and `finish()`. Its signal reports sent, reaped, or
  failed. Each stream is the null device, a caller's file handle, or a captured pipe. `finish` throws when a wait finds
  no child, so no status is made up. It keeps the old `status` and adds the exit case. It stops reading a captured pipe
  at the reap, so a process the helper started cannot hold it open. Three moved callers had no hang guard and now get
  a 60 s SIGKILL, so a hang fails one test instead of the run. The closed-output test of `uniterm ask` now hands the
  command a pipe it owns and closes both ends right after the spawn, since the handle reads its captured pipes itself.
  The SIGINT checks moved from the bare status to the exit case, such as `.exited(130)` for the helper and
  `.signalled(SIGINT)` for `uniterm ask`, so a death by signal can no longer pass for an exit. Correction of fact:
  M2's reaper bullet said "The reaper waits with `waitid` and `WNOWAIT`, sets the reaped flag under the lock, and
  only then reaps with `waitpid`". On Darwin that wait also returns for a stopped child, and the reaper would then
  refuse every later signal. The bullet now says the reaper takes a stop report with a wait for stops alone, and
  waits again. (run best guess)
- 2026-11-25: The row review of M1-M2 amended M3 and two settled decisions. M2 and the driver fix added signal sites
  that M3's search would find. The pause test in `ExecDriverChannelTests` sends its driver SIGSTOP and SIGCONT by pid.
  It now sits under "Reaped by other code in the test process", and M3 moves it to the sender on the token path, since
  the driver is a child of the test process. The thread-directed `pthread_kill` in `HelperHandleTests` names no
  process id, so M3 exempts it. M3's exemption list said "So are tests that signal their own child before their own
  `waitpid`, and `HelperProcess.kill`, which signals under its reaper's lock". The stopped-state reader was copied
  into two test files, so `ProcessTestSupport` now holds it. "Production keeps its rules" said "The one production
  change is how two kills name their target". That stopped being true once "Keep a stopped exec driver from reading
  as exited" fixed a bug found along the way, so the decision now names that change as the planned one and the fix as
  separate. Correction of fact: "How a test signals a process it does not reap" cited
  `BrowserHungProcessTests.swift:218`, which M1 moved. It now names the `policy(_:log:sample:)` helper.
  (run best guess)
- 2026-11-25: M4's mechanisms were chosen in the work-queue run. The guarded call is
  `ProcessInspection.signal(_:pid:startedMicroseconds:)`, and its result is `SignalResult`. The reader is
  `startTimeMicroseconds(of:)`. The browser's identity is `ContentProcessIdentity`, read by an `identify` seam beside
  `sample`, and its `Signal` seam returns the call's result so `kill` can log it. The REPL's identity is
  `ProcessReaper.Target`. `ProcessReaper.kill` still returns nothing, and an internal `guarded(delay:signal:)` builds
  `.live` and does the logging, so a test can feed it each result. The watch arms no bound when it cannot read the
  identity at the close, since a kill could then name only the pid. A token signal that fails with an errno other
  than ESRCH reports unreached. The token read rejects a token whose pid field is not the pid it was read for.
  Correction of fact: "How a test signals a process it does not reap" said nothing about signal 0. The token signal
  answers EINVAL for it. So a signal 0 probe through the call reports unreached with a token, and without one the
  pid path sends it. The decision now says so, and signal 0 probes stay outside the call. (run best guess)

## References

- ADR-07: Failure isolation
- ADR-08: UI responsiveness
- `spec/flaky-tests.md`
- UTERM-045, whose closing rule in the `spec/flaky-tests.md` Rule section decides when this proposal's entries move to
  Fixed
- 2026-11-27: M3's mechanisms were chosen in the work-queue run. The fixture moved to `ScriptTestSupport` with a public
  API, and `ProcessTestSupport` holds `ProcessRecord`, `ProcessSender.signal`, `ProcessSender.send`, and the stopped-state
  reader. `ProcessSender.send` exists because `BrowserHungProcessTests`' injected signal closure must return what the
  guarded call reported. Correction of fact: M3's list left out sites that its search would find. They are
  `BrowserRecoveryTests`' `WebContent.kill` and its defers, the defers in `BrowserHungProcessTests`, `MarkdownRig`,
  `ExecPaneTests`' driver kill, `ExecDriverChannelTests`' grandchild kill, and `ScriptReplLimitsTests`' SIGSTOP. M3 now
  names them. `WebContent.kill` is renamed `crash`, so the search finds no `kill(` on a content process. `login` takes the
  pid path and every other tree member the token path, so the terminal tests pick the expected path from the
  executable's name. A new terminal test sends SIGCONT to each live member through that path. (run best guess)
