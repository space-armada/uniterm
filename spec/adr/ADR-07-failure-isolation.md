# ADR-07: Failure Isolation

**Status:** accepted
**Date:** 2026-11-02

## Context

uniterm hosts work it does not write or control: shells and the programs they run, applets, and scripts. A window can
hold many panes, and the user may have long-running sessions in any of them, such as an ssh session or a build. When
one part fails by crashing, running out of memory, or hanging, the user should lose that part, and nothing else.

UTERM-003 met this first. Janet has no heap limit, and its default out-of-memory handling exits the process. Run
inside the app, one runaway script would end every shell in every window, with no quit confirmation.

## Decision

A failure in one part of uniterm ends at most that part. It never ends the app or another part.

- A part is an applet, a script, a helper process, or a program running in a pane.
- Work that can crash, exhaust memory, or stop answering, in a way uniterm cannot catch and recover from in-process,
  runs where its failure can be contained. When a runtime gives no safe way to bound or stop it in-process, that is a
  separate process.
- A design that lets one part's failure end the app states why isolation is not possible there, and what bounds the
  exposure.
- libghostty is one such exception. Its terminal surface draws into a view inside the app, and moving it to another
  process would mean remoting its rendering and input, which libghostty does not support. The exposure is bounded by
  ADR-01, which confines libghostty to one module behind uniterm's own protocol, and by pinning it to one exact,
  tested version.

## Rationale

A terminal is where users keep work they cannot easily rebuild: remote sessions, long builds, and unsaved state in
editors. Losing all of it because one script or applet failed costs the user far more than the isolation costs to
build. Users judge the whole app by its worst failure, so containing failures keeps one defect from looking like
uniterm being unreliable.

Containing a failure in-process is often impossible. Nothing can safely stop a thread, reclaim a heap after an
allocation fails, or recover after a runtime calls `exit`. A process boundary makes stopping and cleaning up a failed
part safe, and lets the OS reclaim what it held.

## Consequences

- Janet runs in helper processes, never in the app. `scripts/check-janet-isolation.sh` enforces this in `make check`.
  See UTERM-003 "Where scripts run".
- The image decoder and the RTF and Word reader run in helper processes for the same reason. See UTERM-006
  "Rendering" and UTERM-007 "RTF and Word use the system readers".
- Each new applet or integration that hosts code uniterm does not control has to show how its failures are contained.
- Process isolation costs a second executable, a message protocol with a version handshake, and a round trip per call.
- A crash inside libghostty ends the app. A later decision that revisits terminal hosting has to weigh this rule.
- PDF is a second stated exception. PDFKit's view needs the document in the app's process, so PDF parses there.
  UTERM-007's risk "A hostile PDF corrupts or takes over the app" states what bounds it.
- Telling the user what failed is each design's own concern. UTERM-003 settles it for helpers: a REPL pane shows the
  message, and a run reports it on stderr.

## Alternatives Considered

- **Run everything in-process and harden each runtime.** Some failures, such as a runtime's own `exit` on out of
  memory, cannot be hardened from outside it. The app stays exposed to every defect in every runtime it hosts.
- **Decide isolation case by case, with no rule.** Each proposal would weigh isolation against convenience on its own,
  and convenience usually wins until a failure shows the cost.

## References

- UTERM-003: "Where scripts run"
- UTERM-006: "Rendering", the image decoder helper
- UTERM-007: "RTF and Word use the system readers", and the risk "A hostile PDF corrupts or takes over the app"
- ADR-01
- ADR-05
- ADR-10
