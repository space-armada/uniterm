# UTERM-010: Canvas Applet

**Status:** draft
**Created:** 2026-10-31
**Updated:** 2026-11-01

## Dependencies

- UTERM-001
- UTERM-004

## Summary

A canvas applet that programs draw on. A program sends drawing commands, and the canvas renders diagrams, shapes, and
text.

## Motivation

Programs sometimes want to show a diagram, not text. A canvas pane gives them a place to draw, like an HTML canvas. It
is also a building block for the presentation example in UTERM-004.

## Design Decisions (Settled)

### Programs draw, users view

The canvas is driven by a program. It is not a drawing tool for the user.

## Design Decisions (Open)

### How the canvas differs from the image and data viewers

The write-up has not yet worked out where canvas ends and the image and data viewers begin. Settle this before the
design.

### Drawing model

Options:

- **Immediate mode,** like an HTML canvas. The program sends draw calls. The canvas keeps only pixels.
- **Retained mode,** like SVG. The program sends shapes. The canvas keeps them and can redraw, scale, and hit-test.
- **SVG documents.** The program sends whole SVG documents, rendered by WebKit.

### Command format

The wire format for drawing commands, and whether it reuses the UTERM-004 exec format.

### Interaction

Whether user clicks on the canvas go back to the program.

### The applet contract

Context from UTERM-001, which shipped the applet contract. ADR-05 and ADR-06 cover its lifecycle and its description
versioning. An ADR for the rest of the contract is a candidate in UTERM-001's Decision Log. This proposal may reshape
it, so it is not written yet. Every applet implements:

- A view the pane hosts, a title, and status bar segments.
- `start`, `focus`, and a palette update.
- `close`. uniterm sends this lifecycle event, and each applet owns its response, per ADR-05. uniterm keeps no closed
  applet alive. An applet that keeps work going after close owns its bound and a visible indicator.
- `isRunningSomething` and `runningLabels`. Closing a pane, a window, or the app asks first when an affected pane is
  running something, and the dialog names it.
- `describe()`, an inert description with a type and a per-type version. Undo and layout restore both rebuild the
  applet from it, in the same place. Undo is not a snapshot of running state. An applet that wants undo to bring back
  more saves it in its description. ADR-03 says restoring it never runs a program the user did not ask for. ADR-06
  says the applet owns its payload and its version. It upgrades its own older versions, and bumps the version on any
  change an older build cannot round-trip. A description this build cannot read is kept byte-for-byte.

For the canvas: a description likely holds the drawing, or the commands that made it. When a program drew it,
restoring must not run that program again.

## Risks

- **The drawing command set grows into a large contract** — likelihood: medium, impact: medium.
  Mitigation: version the command set. Start with a few primitives: lines, rectangles, circles, paths, and text.

## Milestones

### M1: Draw primitives

**Status:** NOT STARTED

- A pane can run the canvas applet
- A program draws lines, rectangles, circles, paths, and text on it
- The drawing keeps its proportions when the pane resizes

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-11-01: Added "The applet contract" with context from UTERM-001's implementation.
- 2026-11-27: The user retired the `detach` and `reattach` lifecycle events, and ADR-05 is amended to match. "The applet
  contract" said "`detach`, `reattach`, and `close`. uniterm sends these lifecycle events, and each applet owns its
  response, per ADR-05. On detach an applet pauses audio, video, and alerts at once." It now lists `close` alone.

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, APPLET-6
