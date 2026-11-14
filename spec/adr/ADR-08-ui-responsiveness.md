# ADR-08: UI Responsiveness

**Status:** accepted
**Date:** 2026-11-02

## Context

AppKit draws, handles input, and runs every applet on the main thread. While the main thread waits, every window stops
responding: no typing, no resizing, no closing a pane. uniterm hosts work whose duration it does not control, such as
scripts, helper processes, and the programs in its panes.

UTERM-002 and UTERM-003 met this together. UTERM-002 settles that registry actions run synchronously on the main thread.
A script that registered a command, waiting on the main thread while the main thread waited on the script, would
deadlock the app.

## Decision

The user interface stays responsive to the user. The main thread never waits on work whose duration uniterm does not
bound.

- Unbounded work includes scripts and their helper processes, child processes, other processes' replies, the network,
  and anything that waits for the user in another context.
- Such work runs off the main thread or in another process. The main thread sends it a request and returns. The reply
  arrives as a later event on the main thread.
- The main thread may do local work whose duration uniterm bounds, such as a write of a known, small size.
- A design that must wait on the main thread names the bound that keeps the wait short.

## Rationale

A user who cannot type, close, or cancel has lost control of the app, whatever the cause. A wait whose length depends
on outside work has no bound uniterm can promise. Two parts that wait on each other across the main thread deadlock,
and a send-and-return rule rules that out by construction. A watchdog or timeout only shortens the freeze, and still
leaves the user stuck for its length.

## Consequences

- Script host calls are messages, and nothing on the main thread waits for a script's reply. See UTERM-003 "Where
  scripts run".
- Any later Janet-backed command or availability check must answer without the main thread waiting on Janet. UTERM-002's
  risk "UTERM-003 calls the main-thread registry from a Janet thread" already requires this.
- Results that depend on outside work arrive later, so the UI needs a state for "pending", such as a status message.
- Code that is simpler as a blocking call has to be written as a request and a later reply.

## Alternatives Considered

- **Allow waits with a timeout.** The UI still freezes for the timeout, and choosing it trades false failures against
  long freezes.
- **Decide case by case.** Each wait looks short when it is written. The waits that freeze the app are the ones whose
  other side changed later.

## References

- UTERM-002: "Command source", and the risk "UTERM-003 calls the main-thread registry from a Janet thread"
- UTERM-003: "Where scripts run"
- ADR-07
