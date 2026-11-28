# Closing a terminal whose shell is stopped may hang the app

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27
**Estimate:** small; no open design decisions

## Observed

A terminal session's close blocks while the session's process group is stopped. It returns only when the group
continues. Close runs on the main thread, so the app would stop answering.

Found on 2026-11-27, while suspend and resume for controllers was built. A package test started a real libghostty
session running `sh -c "sleep 30 & wait"`, sent the group SIGSTOP, and closed the session. The close never returned.
The test runner aborted the test process after about 130 seconds. The test was removed.

The REPL pane does not have this problem. It continues its helper's group before it closes the session. So does an
exec driver's close.

A plain terminal has no such step. A user can stop a shell from another terminal with `kill -STOP <pid>`. Closing that
tab, closing its window, or quitting would then reach the same close.

## Cause

Traced on 2026-11-27 in the pinned libghostty, `src/termio/Exec.zig`, `killPid`. Freeing a surface sends SIGHUP to the
child's process group in a loop. It stops only when `waitpid` reaps the child libghostty tracks, which is `login(1)`. A
stopped `login` never acts on the hangup, so the loop never ends.

Stopping only the shell does not hang the close. `login` is not stopped, so it takes the hangup. The report's first
steps, `kill -STOP <shell pid>`, close in under a second. The hang needs `login` stopped too, as `kill -STOP -<group>`
leaves it.

## Repro

Not tried in the app. Expected steps:

1. Open a terminal tab and note the shell's pid with `echo $$`.
2. From another terminal, run `kill -STOP <pid>`.
3. Close the first tab.

Expected: the tab closes. Suspected: the app stops answering until `kill -CONT <pid>` runs.

## Fix

Needs a design call. The options:

- The terminal applet continues its own session's group before it closes the session, as the REPL pane does. A SIGCONT
  to a running group does nothing. ADR-05 P2 keeps the host from signalling an applet's work, so the applet would do
  this itself.
- The close moves off the main thread. The app stays responsive, and the stopped shell lingers until it continues.
- Patch libghostty so teardown does not wait on a stopped child.

## Fix note

`GhosttySurfaceView.close()` now continues the child's process group before it frees the surface. The child's identity
is the one libghostty reports at the start. The signal goes only to a group that child leads, and only while the child
is still the process that started. A continue to a running group does nothing. The terminal tab, the window close, and
quit all reach this close.

`testCloseReturnsWhenTheWholeSessionIsStopped` stops `login`, the shell, and `sleep`, then closes the session. It failed
before the fix, with `close()` blocked for 8.4 seconds until the test's own rescue continued the group. It passes in
0.6 seconds after. A test that stops only the shell passed before the fix, so none was added. The app's own close path
was not driven by hand.
