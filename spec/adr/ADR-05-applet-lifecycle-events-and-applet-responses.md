# ADR-05: uniterm Owns the Applet Lifecycle Events, and Each Applet Owns Its Response

**Status:** accepted
**Date:** 2026-11-01

## Context

Each pane runs one applet. uniterm decides when an applet starts and when it ends. Only the applet knows what those
moments mean for its own content. A terminal, a browser, and a media
viewer each have different work in flight.

Undo close reopens a pane in the same place with the same applet. It is not a snapshot of a running process. An applet
that wants an undo to bring back more than its description can carry is free to do so. That is its own concern.

The applet is the only part that knows what its work is, so it is the only part that can stop it correctly. A host that
reaches into an applet's work, such as by signalling a terminal's processes, has to understand every applet's
internals and still gets edge cases wrong.

A host that keeps closed applets alive makes every applet pay for a feature that only some want. It also makes the host
responsible for work it cannot see.

Some state is too costly to keep in a description all the time, such as a terminal's scrollback. The layout is saved on
every change, but such state only needs saving once, as the app quits. Only the host knows when that last save happens.

## Principles

- **P1**: uniterm defines the applet lifecycle and sends its events. Each applet decides how it responds. The events are
  start, willQuit, and close. Close means the host is done with it.
- **P2**: uniterm sends each event when it happens, and does nothing else on the applet's behalf. It never keeps an
  applet alive after closing it, and it never stops or signals the applet's work itself.
- **P3**: Struck on 2026-11-27; see Amendments.
- **P4**: What an applet does after close is its own choice. It may end at once, finish its work after a delay, or save
  more state into its description. Any work it keeps alive after close must be bounded in time and visible to the user.
- **P5**: Undo reopens a closed pane from its description, in the same place, with the same applet type.
- **P6**: willQuit means the app is quitting and the layout is saved next. An applet may put into its description then
  what is too costly to keep there all the time. Only the instance that saves the layout sends it, so an applet never
  saves for a layout that is not written.

## Consequences

- Hiding a view is not a lifecycle event. An applet in a hidden, minimized, or covered window keeps running, and so does
  one in a pane uniterm hides. Sound it plays carries on, and its alerts go out when they happen.
- What an applet does with its own content that is off screen, such as a tab that is not selected, is its own choice.
- An undo restores what the applet's description carries, and no more. A terminal's undo gives a fresh shell in the
  same directory.
- Since undo cannot restore a running session on its own, a close that would end running work asks the user first.
- An applet that keeps work alive after close owns its bound and its indicator.
- State saved only at willQuit is lost after a crash or a force quit.

## Alternatives Considered

- **The host keeps closed applets alive for a grace period.** This gives an exact undo, but the host must keep every
  applet quiet and bounded without understanding it. For a terminal, that means stopping its processes with signals.
- **The host sends detach and reattach when an applet leaves the screen and comes back.** An applet then pauses audio
  and video and holds back alerts while unseen. Nothing leaves the screen and stays alive since P2 and P5, and stopping
  sound because a view is hidden breaks what a Mac app does when its window is hidden.
- **Applets watch for the app's own termination notice.** The order between an applet's observer and the host's last
  save is not defined, so an applet could save after the layout is already written.

## Amendments

- 2026-11-26: Numbered the Decision's statements as principles P1 to P5, and moved the Rationale into Context, with no
  change in meaning.
- 2026-11-26: Added willQuit to P1's events and defined it in P6. Some state is too costly to describe on every layout
  save, and only the host knows when the last save happens. Removed from P1: "The events are start, detach, reattach,
  and close."
- 2026-11-27: Removed detach and reattach from P1's events, and struck P3. The events were sent for a closed applet
  kept alive for undo. P2 and P5 ended that, so no applet leaves the screen and stays alive. Hiding a view is not such
  a moment. By P2 uniterm does nothing on the applet's behalf then, and a Mac app keeps playing sound while its window
  is hidden, so stopping it would surprise the user. Removed from Context: "uniterm decides when an applet starts, when
  it leaves the screen, when it comes back, and when it ends." Removed from P1: "The events are start, detach,
  reattach, willQuit, and close. Detach means the applet has left the screen and stays alive. Reattach means it is
  back." Removed P3: "On detach, an applet stops at once what the user would notice but cannot see. It pauses audio and
  video, and it holds back alerts." Removed from Consequences: "Each applet defines what pausing means for it. An
  applet with nothing perceptible to pause has nothing to do on detach." Removed from Alternatives Considered: "**The
  host defines events only, with no duties for applets.** This is simpler, but nothing would stop an applet from
  playing audio from a pane the user cannot see."

## References

- UTERM-001: "What undo close restores" and "Guarding a close that would kill running processes"
- ADR-03
- ADR-06
