# Closing a terminal whose shell is stopped may hang the app

**Status:** open
**Validation:** not confirmed in the app; a package test showed the hang at the session level

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

Not traced. The block is inside libghostty's surface teardown, which waits on the child. A stopped child cannot act
on the hangup it is sent until it continues.

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
