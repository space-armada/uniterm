# ADR-16: A Program Can Name What It Made

**Status:** proposed
**Date:** 2026-11-26

## Context

Programs place things in uniterm's windows. A script or controller opens panes and lays out groups. It opens terminal
tabs and browser tabs. It shows documents and images in the text and image viewers, puts pins on a map, asks questions
in a Questions pane, and sends content into a pane. Once the viewers hold several tabs, every applet a program can reach
may hold more than one place it could mean.

A program that made something usually acts on it again. It navigates the tab it opened, zooms the image it showed, or
closes the pane it laid out. To do that, it has to say which place it means.

Without an identity, a program has to guess. It can search the places it may see by position or by title. Or it can
match an event or a listing to the operation it ran. The user opens, closes, and renames places while the program runs,
so any guess can land on the wrong place.

These places must follow this rule: the terminal's and the browser's tabs, the data, text, image, and map viewers once
they hold tabs, the Questions pane, and panes and groups a program lays out. So must the planned opens in UTERM-018,
UTERM-049, and UTERM-062.

## Principles

- **P1**: A program knows the identity of every place it makes, or puts content into, from the moment uniterm accepts
  the operation. It never has to find that place again by position, title, or a later event. A place is a pane, a
  tab, or any later kind of thing a program can address. A program can only act again on what it can name. Any other
  way of finding it can pick up a place the user opened or changed in between.
- **P2**: When a place comes into being only after uniterm accepts the operation, the program knows which operation will
  name it, and learns the place's identity once it exists. One example is a place that waits on the user to pick a
  file. The program then still never has to guess. This composes with ADR-11, which already has an operation with a
  later result answer at once.
- **P3**: A command acts on the place its requester designates, and a program designates a place by naming it.
  uniterm never fills in a program's target from the user's focus or selection. The user designates by focus, which is
  the user's own and moves only when the user moves it. A program has no focus of its own. Borrowing the user's would
  aim its command wherever the user happens to be, which is neither what the program meant nor what the user chose.
  The action is the same whoever asks, as ADR-15 requires. Only how the requester points at its target differs.

## Consequences

- Every operation that makes or fills a place, in every applet and on every wire, must give the program the place's
  identity. Changing an existing operation's answer lands in place while its wire is at 0, under ADR-13 C1. From
  version 1 it is a new version under ADR-13. Some changes then wait on that wire's version negotiation.
- Some operations do not meet P1 today. ScriptWire's `send` answers with nothing, and the viewers' commands that show a
  file do not name a tab.
- A program has to keep the identities it was given. Listing places does not say who made them, so a program that loses
  track cannot always tell its own places from the user's.
- A program learns that a place closed when its next command naming it fails. Nothing tells it sooner.
- A program's command that names no place has nothing to act on. A program that wants its own place, or a place that
  matches some description, has to find that place's identity first.

## Alternatives Considered

- **Report identities only in events, or let the program find them by listing.** The program must match a later event
  or a listing to the operation it ran. The user may have opened or closed places in between, so the match is a guess.
- **Let the program choose the identity in its request.** It meets the same goal. It also lets two programs claim one
  identity, so uniterm would need to refuse a clash. P1 does not depend on who picks the identity.
- **Act on the selected place when a program names none.** It suits one-shot scripts. A user's tab switch then silently
  redirects a running program's command.
- **Act on the place the caller last used when it names none.** It keeps a program on its own place. It is also hidden
  state kept for each caller, which every program has to reason about.
- **Identities that survive a relaunch.** No program holds a reference across a relaunch. Restore runs nothing, under
  ADR-03, and no live binding is saved, under ADR-14. So nothing would use such identities.

## References

- [UTERM-062](../proposals/UTERM-062-viewer-tabs.md): "What a program's open does"
- [ADR-02](ADR-02-pane-tree-nodes-have-stable-ids.md): stable, retired identity for pane-tree nodes
- [ADR-11](ADR-11-deferred-applet-replies-never-hide-effects.md): a command with an effect answers at once
- [ADR-13](ADR-13-outside-wires-stay-compatible-across-versions.md): each version keeps one fixed meaning
- [ADR-14](ADR-14-a-controller-controls-what-it-opened.md): what a program opened defines its reach
- [ADR-15](ADR-15-a-programs-operation-is-the-users.md): a program's operation is the user's
