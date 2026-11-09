# UTERM-018: Open in the Nearest Capable Pane

**Status:** draft
**Created:** 2026-11-08
**Updated:** 2026-11-08

## Dependencies

- UTERM-015: the file router, its type declarations with ranks, the routed-open anchor, and the Launch Services
  sender rules this proposal builds on
- UTERM-005: the browser applet, its tabs, and its one shared website data store
- UTERM-007: the text viewer's link policy, which today hands every web link to the default browser
- UTERM-003 and UTERM-004: the host API and control powers a script or controller would open through
- ADR-02: panes are addressed by stable ID, which the walk uses to find the origin and its neighbors
- ADR-09: a script or controller opening content in a pane needs an authenticated requester and an explicit grant

## Impacts

- UTERM-015 — "How a file type maps to an applet" and the routed-pane placement: a routed file goes to the nearest
  pane that opens its type, instead of always to a new pane beside the source. M6 "Terminal clicks": a Cmd-click on a
  web URL stops doing nothing.
- UTERM-007 — "Markdown rendering" and M1's link checks: a clicked web link goes through the walk instead of straight
  to the default browser.
- UTERM-005 — the browser gains an entry point that opens a URL as a new tab, and its non-web scheme hand-off goes
  through the same rule.
- UTERM-004 — "telling the nearest browser pane to open a page" becomes one case of this walk, under whatever power
  M5 settles.

## Summary

Every open in uniterm follows one rule. An open starts at the pane it came from and walks outward through the pane
tree to the nearest pane that can handle it. That pane opens it the way it opens anything: the browser adds a tab, and
a viewer replaces its document. When no pane in the window can open it, the user chooses between letting macOS handle
it and cancelling.

The rule covers links clicked in any applet, files from Finder and File > Open, Cmd-clicks in the terminal, and
requests from scripts and controllers.

## Motivation

A hand check of the text viewer found that a web link in a PDF opens the system browser, not uniterm's browser pane.
That was the text viewer's settled decision. It was decided for one applet, though, and every other applet that opens
something decides again. The file router makes a new pane beside the source. The browser hands non-web schemes to
other apps. The terminal leaves Cmd-click to libghostty.

The user wants one principle instead: content opens in the nearest pane that can show it. Starting at the origin
means a Ctrl-click in a browser opens a tab in that same browser. A link in a document lands in the browser pane
beside it, if there is one. Nothing opens in another window the user isn't looking at.

## Design Decisions (Settled)

### One walk for every open

Every open is a request with an origin pane, a target, and a kind of open. The target is a URL or a file. The walk
asks the origin pane first whether it can open the target. Then it asks the panes ever further from the origin, until
it reaches the window's root. The first pane that can open the target handles it. The walk never leaves the window.

Rationale: the user stated the principle. Starting at the origin makes in-pane opens, like a browser's new tab, fall
out of the same rule. Staying in the window keeps an open from landing somewhere the user isn't looking.

### Sources

The walk covers four sources:

- Links clicked in an applet: the text viewer's PDF, RTF, Word, and Markdown links, and the browser's own new-tab
  clicks and non-web scheme hand-offs
- Files opened from Finder, the Dock, and File > Open (Cmd-O). Each applet's pane-local Open… stays as it is: it
  always opens in its own pane.
- A Cmd-click on a URL or path in a terminal pane
- Open requests from Janet scripts and UTERM-004 controllers

### An open with no origin pane

A Finder or Dock open, Cmd-O with no pane focused, and a script with no pane of its own have no origin pane. The walk
then starts at the focused pane of the frontmost window, the anchor UTERM-015 already uses for routed opens.

### What a pane does with an open

The pane interprets the open. A browser opens the URL as a new tab, after the current one, selected. A viewer
replaces its document, exactly as its own Open… does. The replaced document stays reachable through Reopen
(Cmd-Shift-T), the way a closed pane's description is. A terminal pane that can open a folder opens it the way
UTERM-015 already defines.

### No capable pane

When no pane in the window can open the target, uniterm asks the user once: let macOS handle it, or cancel. Cancel
does nothing, so the user can open a suitable pane and try again. For a web link, macOS means the default browser.

### Several capable panes

When more than one pane is equally near, the walk picks one by a fixed rule and does not ask. A better tie rule waits
until the simple one proves wrong.

### Document links use the shared browser session

A link from a document opens in the browser's one persistent website data store, the same as any other browser tab.
Logins carry over. A document's author can therefore trigger a GET that carries the user's cookies, as a link in Mail
already can when it opens the default browser. Risks records this.

## Design Decisions (Open)

### The capability contract

Original question: how a pane says what it can open. UTERM-015 already has each applet declare the content types it
opens, with a rank. The walk also needs URL schemes, and maybe kinds of open (new tab, replace, reveal). Candidates:

- Extend `AppletTypeDeclaration` with schemes, and ask the live pane at walk time whether it can open the target now
- A per-instance query only, so a pane can decline, such as a viewer with unsaved state or a browser at its tab limit
- Both: the declaration filters, and the live pane confirms

### How "nearest" is measured

Candidates: steps up the split tree to the first shared ancestor, then down; or UTERM-004's shortest edge distance
from the source pane in the normalized tree, which already ranks "the nearest browser pane". Using UTERM-004's metric
keeps one meaning of "near" in the app.

### The tie rule

"Several capable panes" settles that ties take a fixed pick. Which one is open: reading order, the most recently
focused, or UTERM-004's tie rule.

### Rank versus distance

A nearer pane may open the target at a lower rank than a farther one. A text viewer is the owner of Markdown. A
browser could be an alternate. Candidates: distance always wins; rank wins within a window; or rank filters first and
distance picks among the top rank.

### Scripts and controllers

ADR-09 makes each effect a separate power. Opening a URL in a browser pane loads remote content as the signed-in
user. Opening a file reads it under uniterm's privacy grants, which UTERM-015's path-reading power governs.
Candidates: a new "open" power; extend UTERM-004's pane control with navigation; or fold URL opens into UTERM-005's
existing power for program-created browser panes. A script also needs an origin pane, which may be its REPL pane or
none.

### How a link-opened tab restores

ADR-03 allows a restored browser tab to reload, and UTERM-005 restores only the selected tab. A tab a document opened
carries a URL the document's author chose, and every relaunch would fetch it again. Candidates: restore it like any
tab; restore it unloaded until selected, as UTERM-005 does for unselected tabs; or mark it so restore shows the URL and
waits.

### The prompt when nothing opens a file

For a file from Finder, "let macOS handle it" can route straight back to uniterm, when uniterm is the file's default
app. Candidates: offer "Open in a new pane" in place of macOS for files; offer the other apps that open the type; or
offer only cancel.

### Plain clicks and modifier clicks in the browser

A plain click on a link navigates the tab today. A Ctrl-click or Cmd-click asks for a new tab, which the walk serves
from the browser itself. Open: whether a modifier should skip the origin and send the link elsewhere, such as the
default browser.

### Terminal links from remote output

UTERM-015 counts a terminal Cmd-click as the user's act only on a target shown on Cmd-hover, since OSC 8 text can
differ from its target. Open: whether a web URL from remote output, such as an SSH session, opens through the walk
without asking, or needs the same marker and confirmation as a remote path.

### Where the walk's code lives

Candidates: a window-level router beside UTERM-015's `RoutedOpener`, which every applet reaches through a new host call;
or an injected `URLOpening` per applet that resolves through the window. UTERM-015's router already owns anchors and
placement, so the first keeps one owner.

## Risks

- **A document's author can trigger authenticated requests** — likelihood: medium, impact: medium. A link in a
  document opens in the shared browser session, so a one-click confirm link runs as the user when clicked.
  Accepted: the user chose the shared session. The link still needs a real click, and the browser already treats a
  page's links the same way. The "How a link-opened tab restores" question decides whether a relaunch repeats it.
- **Replacing a viewer's document surprises the user** — likelihood: medium, impact: low. A file opened from Finder
  may replace what a nearby viewer showed. Mitigation: the replaced document stays reopenable, and the walk only
  replaces in a pane that would open the same kind of content.
- **UTERM-015's placement tests and behavior change** — likelihood: high, impact: medium. Its routed-pane placement is
  built and tested. Mitigation: a milestone amends UTERM-015 and moves its placement tests to the walk, in one change.
- **The capability contract becomes a cross-applet contract** — likelihood: high, impact: medium. Every applet, and
  every later one, declares what it opens. Mitigation: the contract builds on UTERM-015's type declarations, which
  applets already make, and the open questions settle its shape before any milestone ships it.
- **Script and controller opens widen the control surface** — likelihood: medium, impact: high. Opening content in a
  pane is a new effect. Mitigation: per ADR-09 it waits on a named power, and its milestone depends on UTERM-004.

## Milestones

### M1: The walk and the capability contract

**Status:** NOT STARTED

- Each applet declares what it opens, and the walk asks the origin pane first, then ever farther panes, up to the
  window's root
- The walk is tested with fixture applets and fixture pane trees, with no production viewer
- With no capable pane, the user is asked to let macOS handle the open or to cancel, and cancel does nothing
- An open with no origin pane starts at the frontmost window's focused pane
- The walk never chooses a pane in another window

### M2: Links from the text viewer and the browser

**Status:** NOT STARTED

- A web link clicked in a PDF, an RTF or Word document, or Markdown opens as a new tab in the nearest browser pane in
  the window
- With no browser pane in the window, the user is asked, and macOS opens the link in the default browser
- A Ctrl-click or Cmd-click on a link in a browser pane opens a new tab in that same pane
- The browser's non-web scheme hand-offs go through the walk, and still ask before opening another app
- A link opened this way uses the browser's shared website data store

### M3: Files from Finder and File > Open

**Status:** NOT STARTED

- A file from Finder, the Dock, or Cmd-O opens in the nearest pane that opens its type, and replaces that pane's
  document
- The replaced document comes back through Reopen
- Each applet's own Open… still opens in its own pane
- UTERM-015's routed-placement tests are amended to the walk, and its proposal records the change

### M4: Terminal clicks

**Status:** NOT STARTED

- A Cmd-click on a web URL or OSC 8 link in a terminal pane opens through the walk
- A Cmd-click on a path opens through the walk, under UTERM-015's rules for who may open
- The open-URL action reaches the app through the terminal surface protocol, per ADR-01

### M5: Scripts and controllers

**Status:** NOT STARTED

- A script or controller can ask to open a URL or a file through the walk, only under the power the open question
  settles
- An open from a script with no origin pane starts at the frontmost window's focused pane
- A request without the power is refused before any pane is touched

## Decision Log

- 2026-11-08: Drafted after the UTERM-007 hand check, where a PDF's web link opened the system browser. The user asked
  for cross-applet link routing as its own proposal.
- 2026-11-08: Settled with the user while drafting: one walk from the origin pane to the nearest capable pane; all four
  sources; files from Finder and Cmd-O follow it, and pane-local Open… stays; with no origin, start at the frontmost
  window's focused pane; stay in the window; ask macOS-or-cancel when nothing opens; take a fixed pick for ties; use
  the shared browser session for document links; keep a replaced document reopenable.

## References

- ADR-01: libghostty is reached only through the terminal surface protocol
- ADR-02: panes are addressed by stable ID
- ADR-03: restored state never runs a program the user did not ask for
- ADR-04: applets declare their own keys and never take window keys
- ADR-09: control authority needs an authenticated requester and an explicit, scoped grant
