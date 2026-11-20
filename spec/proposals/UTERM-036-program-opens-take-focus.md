# UTERM-036: A Program's Opens and Layouts Take Focus as the User's Do

**Status:** implemented
**Created:** 2026-11-20
**Updated:** 2026-11-20

## Dependencies

- UTERM-015, for routed opens and the approved program's open
- UTERM-004, for layout requests

## Impacts

- UTERM-015 — "Where a routed pane goes": the anchor bullet and the bullet that a program's open takes no focus.
  Superseded in part.
- UTERM-015 — M5 and M7: the checks that an approved open takes no focus and raises no window. Superseded in part.
- UTERM-004 — M4: the check that a published layout leaves focus where it was. Superseded in part.

## Summary

A program's open and a program's layout request land as the same action by the user does. The new pane takes focus.
A new window becomes key, and an existing window the open anchors to comes forward.

## Motivation

ADR-12 was retracted on 2026-11-20. Its rules held a program's changes apart from the same changes made by the user.
A program's open took no focus and raised no window. A layout request left focus where it was. The user set that a
program's operation behaves as the user's.

UTERM-015 and UTERM-004 are implemented, so their text is frozen. This proposal records the change and supersedes the
affected parts of both.

## Design Decisions (Settled)

### A program's approved open

Decision: an approved open from a program lands as a Launch Services open does.

- The anchor's window comes forward, and the app is activated. With no anchor, the app is activated.
- The routed pane takes focus. A new window that holds only the routed pane becomes key.
- The anchor rules of UTERM-015 are unchanged. A `uniterm open` from a terminal session anchors to that session's
  pane. A caller in no session anchors to the focused pane of the most recently key window.

Rationale: a program's operation behaves as the user's. A Launch Services open from the user already brings its
window forward and focuses the routed pane. One path now serves both.

### A program's layout request

Decision: a layout request's new panes are the user's splits made at once. The last new pane the request names takes
focus, as the last of those splits would. A layout that makes no new pane moves no focus.

Rationale: a program's operation behaves as the user's. The user's split focuses its new pane.

## Design Decisions (Open)

None.

## Risks

- **Keys in flight reach the new pane** — likelihood: medium, impact: medium. A user typing in one pane when a
  program's open or layout lands has the rest of their keys go to the new pane. Accepted: the same happens when the
  user's own open lands while they type, and a program's operation behaves as the user's.

## Milestones

### M1: Opens and layouts take focus

**Status:** DONE

- An approved program's open from Launch Services lands beside the focused pane, and the new pane takes focus
- An approved `uniterm open` splits the caller's pane, and the new pane takes focus
- A first layout request focuses its last new pane
- A later layout that makes no new pane leaves focus where it was

**As built:**

- The option that kept a program's open from taking focus is gone, along with the window show that never made a window
  key. A program's open and a Launch Services open run through one path in the coordinator.
- A consent test picked the pane outside a controller's group by reading the focused pane after a layout. It now
  records that pane before the layout.

## Decision Log

- 2026-11-20: Filed after ADR-12 was retracted. The user chose a superseding proposal so the frozen text of UTERM-015
  and UTERM-004 follows the code. The user set that a layout's new panes behave as the user's splits, with the last
  new pane taking focus. The code landed in the commits "Let a program's approved open take focus like the user's" and
  "Let a program's layout focus its last new pane, as the user's splits would".

## References

- UTERM-015: routed opens
- UTERM-004: layout requests
- [ADR-12](../adr/ADR-12-unchosen-changes-never-move-focus-or-arm-input.md): retracted
