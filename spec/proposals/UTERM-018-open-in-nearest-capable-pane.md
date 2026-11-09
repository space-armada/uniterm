# UTERM-018: Open in the Nearest Capable Pane

**Status:** accepted
**Created:** 2026-11-08
**Updated:** 2026-11-09

## Dependencies

- UTERM-015: the file router, its type declarations with ranks, the routed-open anchor, and the Launch Services
  sender rules this proposal builds on
- UTERM-005: the browser applet, its tabs, its one shared website data store, and M8's browser navigation
  permission, which script and controller URL opens use
- UTERM-007: the text viewer's link policy, which today hands every web link to the default browser
- UTERM-003 and UTERM-004: the host API and control powers a script or controller would open through
- UTERM-013: Reopen, which a replaced document joins
- ADR-02: panes are addressed by stable ID, which the walk uses to find the origin and its neighbors
- ADR-09: a script or controller opening content in a pane needs an authenticated requester and an explicit grant

## Impacts

- UTERM-015 — "How a file type maps to an applet" and the routed-pane placement: a routed file goes to the nearest
  pane that opens its type, instead of always to a new pane beside the source. Its batch rule changes: leftovers split
  the origin window before any new window opens. M6 "Terminal clicks": a Cmd-click on a web URL stops doing
  nothing, and "Who may open by terminal click" no longer refuses web URLs on remote-marked output.
- UTERM-007 — "Markdown rendering" and M1's link checks: a clicked web link goes through the walk instead of straight
  to the default browser.
- UTERM-005 — the browser gains an entry point that opens a URL as a new tab, and its non-web scheme hand-off goes
  through the same rule.
- UTERM-004 — "telling the nearest browser pane to open a page" becomes one case of this walk, under browser
  navigation. "Nearest" takes this proposal's tie rule in place of reading order, and shares the walk's metric code.
- UTERM-013 — Reopen gains a replaced document as a kind of entry, beside closed tabs and closed panes.

## Summary

Every open in uniterm follows one rule. An open starts at the pane it came from and walks outward through the pane
tree to the nearest pane that can handle it. That pane opens it the way it opens anything: the browser adds a tab, and
a viewer replaces its document. When no pane in the window can open a URL, the user chooses between letting macOS
handle it and cancelling. A file with no capable pane opens in a new pane beside the origin.

The rule covers links clicked in any applet, files from Finder and File > Open, Cmd-clicks in the terminal, and
requests from scripts and controllers.

## Motivation

A hand check of the text viewer found that a web link in a PDF opens the system browser, not uniterm's browser pane.
That was the text viewer's settled decision. It was decided for one applet, though, and every other applet that opens
something decides again. The file router makes a new pane beside the source. The browser hands non-web schemes to
other apps. The terminal leaves Cmd-click to libghostty.

The user wants one principle instead: content opens in the nearest pane that can show it. Starting at the origin
means a Cmd-click in a browser opens a tab in that same browser. A link in a document lands in the browser pane
beside it, if there is one. Nothing opens in another window the user isn't looking at.

## Design Decisions (Settled)

### One walk for every open

Every open is a request with an origin pane, a target, and a kind of open. The target is a URL or a file. The walk
checks the origin pane first. Then it checks the window's other panes in order of their distance from the origin, as
"How nearest is measured" defines it. The first pane that can open the target handles it. The walk never leaves the
window.

Each source's own filter runs before the walk. A document link still opens only `http`, `https`, and `mailto`, per
UTERM-007. A browser link still refuses `file:` and the other schemes UTERM-005 refuses. The walk never widens what a
source may open. Amended 2026-11-09; see Decision Log.

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

A Finder or Dock open and Cmd-O with no pane focused have no origin pane. The walk then starts at the focused pane of
the most recently key window, the anchor UTERM-015 already uses for routed opens.

A script or controller never takes its origin from focus. Its origin is its source pane, or the source pane the user
granted an unbound caller. See "Scripts and controllers". Amended 2026-11-09; see Decision Log.

### What a pane does with an open

The pane interprets the open. A browser opens the URL as a new tab, after the current one, selected. A viewer
replaces its document, exactly as its own Open… does. The replaced document stays reachable through Reopen
(Cmd-Shift-T), the way a closed pane's description is. See "How Reopen restores a replaced document". A terminal pane
is never a target. A folder for the terminal opens in a new terminal pane, as "Applets whose open makes a new pane"
settles. Amended 2026-11-09; see Decision Log.

### No capable pane

When no pane in the window can open the target, uniterm asks the user once: let macOS handle it, or cancel. Cancel
does nothing, so the user can open a suitable pane and try again. For a web link, macOS means the default browser.

This holds for URLs the user opened, except `mailto:`, which opens the mail app without asking. A file opens in a new
pane instead, by "The prompt when nothing opens a file". A
script or controller open with no capable pane fails with an error and asks nothing. See "Scripts and controllers".
Amended 2026-11-09; see Decision Log.

### Several capable panes

When more than one pane is equally near, the walk picks one by a fixed rule and does not ask. A better tie rule waits
until the simple one proves wrong.

### Document links use the shared browser session

A link from a document opens in the browser's one persistent website data store, the same as any other browser tab.
Logins carry over. A clicked link therefore carries the user's cookies, the same as a link clicked in any regular browser.
Risks records where uniterm could go beyond that.

### The capability contract

Original question: how a pane says what it can open. UTERM-015 already has each applet declare the content types it
opens, with a rank. The walk also needs URL schemes, and maybe kinds of open (new tab, replace, reveal). Candidates:

- Extend `AppletTypeDeclaration` with schemes, and ask the live pane at walk time whether it can open the target now
- A per-instance query only, so a pane can decline, such as a viewer with unsaved state or a browser at its tab limit
- Both: the declaration filters, and the live pane confirms

Decision: static only. The applet type declaration gains URL schemes with ranks, beside the content types it already
declares. The walk matches the target against each pane's applet type declaration and never asks the pane. A `file:`
URL becomes a file target before it is matched.

A pane that cannot open the target right now still gets the open. It handles it the way it handles its own Open…. A
map viewer with unsaved pins asks whether to discard them, and a pane with a question up refuses with a message. The
walk never reroutes to a farther pane because of a pane's current state.

Rationale: one source of truth, testable as plain data, as UTERM-015's declaration already is. No live decline has a
caller. A map viewer's unsaved pins are already guarded by its own discard question. A user's link click never counts
toward the browser's tab limit. A routed folder makes a new terminal pane, which is placement, not capability. A live
query would also route on pane state the user cannot see. A live-only query would declare each file type twice, once
for Launch Services and Open With and once in the query, with nothing to catch the two drifting apart.

### How "nearest" is measured

Candidates: steps up the split tree to the first shared ancestor, then down; or UTERM-004's shortest edge distance
from the source pane in the normalized tree, which already ranks "the nearest browser pane". Using UTERM-004's metric
keeps one meaning of "near" in the app.

Decision: UTERM-004's metric. Distance is the shortest edge distance from the origin pane in the current normalized
pane tree, with group wrappers transparent. The metric is built once in the pane model, and UTERM-004's nearest rule
uses the same code.

Rationale: one meaning of "near" in the app, and UTERM-004 already settled "tree distance, not physical screen
distance". The shared-ancestor level ignores depth. It ranks a deep pane in a sibling subtree ahead of an adjacent
cousin. Screen geometry would give the app a second meaning of near, and its pick would change when a divider moves.

Normalization merges same-axis splits, so repeated splits to the right form one flat row in which every pane is two
edges from every other. Ties are therefore common, and "The tie rule" carries much of the weight.

### Where the walk's code lives

Candidates: a window-level router beside UTERM-015's `RoutedOpener`, which every applet reaches through a new host call;
or an injected `URLOpening` per applet that resolves through the window. UTERM-015's router already owns anchors and
placement, so the first keeps one owner.

Decision: one window-level router, grown from UTERM-015's `RoutedOpener`, owns anchors, the walk, placement, and the
hand-off to macOS. Applets reach it through a new host call. The host is bound to its pane, so the router knows the
origin, and an applet cannot claim another one. Applets stop holding a `URLOpening`. The system opener moves into the
router, behind a seam that tests replace, so tests still launch nothing.

The router's hand-off keeps the browser's rules. It names the app that will open the URL, and `mailto:` opens the mail
app without asking. A web link's "let macOS handle it" names the default browser.

Rationale: one owner for every open, which is the settled "One walk for every open". An opener injected per applet
would keep files on the router and URLs on a second seam. It also cannot know its pane, since an applet is built before
it is placed. A `URLOpening` adapter that forwards to the walk would keep the wrong contract. `URLOpening` names the
app synchronously and returns a result before any prompt is answered, and a `mailto:` link would be asked about twice.

### Scripts and controllers

ADR-09 makes each effect a separate power. Opening a URL in a browser pane loads remote content as the signed-in
user. Opening a file reads it under uniterm's privacy grants, which UTERM-015's path-reading power governs.
Candidates: a new "open" power; extend UTERM-004's pane control with navigation; or fold URL opens into UTERM-005's
existing power for program-created browser panes. A script also needs an origin pane, which may be its REPL pane or
none.

Decision: fold URL opens into UTERM-005's browser navigation as it is specified. A script or controller open walks only
the panes the requester may address: its source pane and the groups it owns, per UTERM-004. A URL open needs browser
navigation, and reaches only browser panes the requester created. A file open needs the path-reading power for the
path, and lands only in a pane the requester may address. The path-reading power governs the read, not the target.

The walk filters by the requester's authority before it ranks by distance, as UTERM-004's nearest rule does. Its
origin is the requester's source pane, and an unbound caller's origin is the source pane the user granted it. With no
capable pane it may address, the request fails with a structured not-found error. It never asks the user and never
hands off to macOS. The permissions keep UTERM-004's versioned meanings and admission, which carry their skew rules.

This leaves one thing undone: a REPL script cannot open a link in the user's own browser pane beside it. Doing that
would need a new power and would reverse UTERM-005's settled conclusion that program opens reach "a program's own
browser panes, not ones the user made".

Rationale: the only candidate consistent with ADR-09, UTERM-004, and UTERM-005, and it adds no scope. Extending pane
control is what UTERM-005 rejected: a script that UTERM-003 denies network access could reach the network through a
browser pane. A new open power, or browser navigation with a widened target scope, would land a controller's open in a
pane the user made. UTERM-004 settles that geometry alone grants nothing, and its nearest rule filters by authority
first so proximity never becomes authority.

### The tie rule

"Several capable panes" settles that ties take a fixed pick. Which one is open: reading order, the most recently
focused, or UTERM-004's tie rule.

Decision: break ties by tree position. For each tied candidate, take the lowest split that holds both it and the
origin. A candidate whose shared split sits deeper in the tree wins, so a pane in the origin's own subtree beats a
cousin. Among candidates that share the same split, the one whose child index there is closest to the origin's wins.
Then reading order decides, then stable pane ID. UTERM-004's nearest rule takes the same tie rule, so the app keeps
one rule. Amended 2026-11-09; see Decision Log.

Rationale: reading order alone ignores the origin. Normalization makes a row of right splits flat, so in [A|B|C] with
origin C every pane is two edges away, and reading order picks A over the adjacent B. Tree position picks B. It uses
topology only, so the pick never changes when a divider moves, and it needs no window size. A geometric tie-break by
shared edge length would flip the pick when a divider moves, which "How nearest is measured" rejects. The most
recently focused pane would add hidden focus history, and UTERM-004 rejected focus-based picks because they change with
unrelated activity.

### Rank versus distance

A nearer pane may open the target at a lower rank than a farther one. A text viewer is the owner of Markdown. A
browser could be an alternate. Candidates: distance always wins; rank wins within a window; or rank filters first and
distance picks among the top rank.

Decision: rank filters first, and distance picks among the top rank. UTERM-015's `FileRouter` resolves the winning
applet unchanged, by the saved per-type choice, then specificity, then owner over alternate, across every applet. Only
panes of the winning applet are candidates, and distance picks among them. URL schemes resolve by rank alone. They
have no saved choice and no chooser, and two applets claiming one scheme at the same rank fail a test, as two applets
claiming one type do. Amended 2026-11-09; see Decision Log. When the
router finds several winners and would ask the user to pick, it asks first, then walks to the nearest pane of the
applet the user picked. When no pane of the winning applet is in the window, the open goes to "No capable pane".

Rationale: one resolver keeps UTERM-015's meaning of saved choice, specificity, and rank. Distance always winning
breaks UTERM-015's settled rule that a saved choice overrides rank. A `.json` saved for the data viewer would replace
the document of a nearer text viewer. A folder from Finder would replace a nearby image viewer's slideshow, where today
it makes a terminal pane. Ranking tiers by the applets present in the window would need a second resolver, and it
silently skips a saved choice whenever that applet has no pane in the window.

### Plain clicks and modifier clicks in the browser

A plain click on a link navigates the tab today. A Ctrl-click or Cmd-click asks for a new tab, which the walk serves
from the browser itself. Open: whether a modifier should skip the origin and send the link elsewhere, such as the
default browser.

Decision: no modifier skips the origin. A plain click navigates the tab. A Cmd-click opens a new tab in the same pane,
which the walk serves from the origin. Nothing in a browser pane sends a link to the default browser. Ctrl-click opens
the context menu on macOS, so it is not a new-tab gesture. The question's premise was corrected.

Rationale: one walk for every open, with no second mode. Cmd-Shift-click already means a new foreground tab in
Safari, so taking it over breaks a convention users rely on. A context-menu item "Open Link in Default Browser" would
be a scope addition the Motivation does not ask for, since its push is to keep links in uniterm. A modifier that skips
to the next browser pane has no caller. Leaves undone: no one-step way to send a link to the default browser. Copying
the link still works.

### How a link-opened tab restores

ADR-03 allows a restored browser tab to reload, and UTERM-005 restores only the selected tab. A tab a document opened
carries a URL the document's author chose, and every relaunch would fetch it again. Candidates: restore it like any
tab; restore it unloaded until selected, as UTERM-005 does for unselected tabs; or mark it so restore shows the URL and
waits.

Decision: restore it like any tab, by UTERM-005's rule unchanged. The browser's description gains no field.

Rationale: a Cmd-click on the same link in a web page also opens a selected tab with a URL the page's author chose. A
marker on walk-opened tabs would guard one of two identical paths. UTERM-005 already accepted the general risk, that a
side-effecting GET runs again when its tab is restored selected, and lazy loading limits it to one tab per pane. A
marker would also bump the browser's payload version under ADR-06, so a downgrade would keep every browser pane as raw
bytes. Restoring every tab unloaded would reverse UTERM-005's settled restore with no new evidence.

### How a batch walks

UTERM-015 settles one pane per file for a batch from Finder, and a batch of many files into one new window. The walk
has no rule for a batch. If every file walked, 20 images would each replace the last in the nearest image viewer, and a
batch with no capable pane would ask 20 times. Open: how a batch of files from one event walks.

Decision: each file walks, in the event's order, and takes the nearest capable pane that this batch has not used yet.
A file left over once the capable panes are used opens in a new pane in the origin window, splitting the largest pane.
A batch file with no capable pane in the window is placed the same way. Once the origin window has no room, the
remaining files go to a new window, splitting its largest pane. A file that still finds no room goes to a further new
window, as UTERM-015 settles. Amended 2026-11-09; see Decision Log. The router's own prompts are asked once for the batch: the confirmation above 10 files,
and one chooser for each ambiguous type.

Rationale: one file and two files behave the same way, and the settled "Sources" makes Finder files walk with no
exception for count. Keeping UTERM-015's batch placement would open two selected files in a new window while one file
walks. Walking only the first file would make which document gets replaced depend on Finder's order, which UTERM-015
calls arbitrary. Walking each file alone would replace one viewer 20 times. Leftovers split the origin window, so a
batch stays in the window the user is looking at until that window is full.

### Terminal links from remote output

UTERM-015 counts a terminal Cmd-click as the user's act only on a target shown on Cmd-hover, since OSC 8 text can
differ from its target. Open: whether a web URL from remote output, such as an SSH session, opens through the walk
without asking, or needs the same marker and confirmation as a remote path.

Decision: an `http` or `https` URL opens through the walk after Cmd-hover has shown its target, with no extra question,
even on output that carries UTERM-015's remote marker. Paths and every other scheme on remote-marked output stay
refused, as UTERM-015 settles. This amends UTERM-015's "a click on marked output opens nothing" for web URLs only.

Rationale: UTERM-015 refuses remote output for two reasons, and neither applies to a web URL. A path names a file on
another host, but a web URL names the same resource from any host, except a local address, which "Loopback and
private addresses from remote output" covers. A program chose the text, but Cmd-hover already
shows the real target. Local output can print any OSC 8 URL too, so remoteness says nothing about who wrote it. The
settled shared-session decision already accepts a clicked link's cookie exposure. Refusing web URLs would buy no
protection and would turn off every web link in a pane for the life of one `ssh` session, on a libghostty that cannot
mark rows. Asking on each click repeats what hover showed. Asking once per pane would be a grant with no owner, scope,
or end.

### The prompt when nothing opens a file

For a file from Finder, "let macOS handle it" can route straight back to uniterm, when uniterm is the file's default
app. Candidates: offer "Open in a new pane" in place of macOS for files; offer the other apps that open the type; or
offer only cancel.

Decision: no prompt for files. When the window holds no pane of the applet that `FileRouter` resolves, the file opens
in a new pane of that applet beside the origin pane, by UTERM-015's built placement. It opens in a new window when
there is no room, a sheet is up, or no window exists. Batch leftovers keep the rule in "How a batch walks". The
macOS-or-cancel prompt stays for URLs. A file type no applet declares is refused before any walk, as UTERM-015 settles.

Rationale: "let macOS handle it" loops when the user made uniterm the file's default app. Launch Services sends the
file back, from a sender that matches no Apple opener, so uniterm refuses it or asks to allow it, and then asks the
same question again. Without that loop, macOS opens another app, which overrides the user's choice of uniterm.

A prompt would also contradict the settled batch rule. A batch leftover already opens in a new pane with no question,
so one fewer capable pane would add a question. A window of only terminals, the most common window, would prompt on
every routed file, where UTERM-015 opens it today with no prompt. Leaves undone: a file open has no one-step hand-off
to another app. Finder's Open With still covers that.

### How Reopen restores a replaced document

"What a pane does with an open" keeps a replaced document reachable through Reopen. Reopen today holds only closed
tabs, which each applet keeps, and closed panes, which the window's ledger keeps with their placement. A replaced
document closes no pane and has no placement. A replace can also be cancelled after the router asks for it: the map
viewer asks "Discard and Open" in a detached task, so the router cannot tell whether the replace happened. Open: the
entry, when it is recorded, and where Reopen puts the old document.

Decision: the applet tells its host when a replace commits, after any discard question. It passes its description
from before the replace. The window pushes that description onto its close ledger as a replaced-document entry,
stamped from the shared counter. Reopen opens the old document in a new pane beside the pane that replaced it, so
Reopen itself replaces nothing. `replaceSource` keeps its signature, and a cancelled replace records nothing.

This covers every replace: a walk open, the pane's own Open…, and a drop. The menu title "Reopen Closed Tab or Pane"
stays, since the old document comes back as a pane and UTERM-013 fixed the title so an App Shortcuts remap keeps
matching. This amends UTERM-013's Reopen with a third kind of entry.

Rationale: one owner, the window's ledger, already holds pane descriptions and survives the pane's close. Reporting
the commit through the host needs no async outcome from `replaceSource`, which four applets implement and several
callers use. Covering only walk opens would make the same replace reopenable or not depending on the gesture.

Restoring in place would need the synchronous reopen contract to become async, for a dirty map viewer's discard
question. Swapping in place pushes the current document as the newest entry. Repeated Reopen would then bounce between
two documents and hide every older close.

### Applets whose open makes a new pane

The terminal declares folders at the owner rank, but it opens a folder by making a new terminal pane, never in place.
Open: whether such an applet's existing panes count as capable, and where the new pane goes.

Decision: for a file target, a pane is capable in place only when its applet can replace its source, which the
applet contract already says through `SourceReplacing`. A URL target is capable in any pane whose applet declares its
scheme, since the browser opens a URL as a new tab, not by replacing a source. No declaration field is added. The terminal's panes are therefore never candidates. A
folder whose winning applet is the terminal takes the file no-capable-pane path, a new terminal pane beside the
origin, as UTERM-015 builds today. A script folder open of that kind fails, since a script open never creates a pane.

Rationale: UTERM-015 settles that a routed folder "is never handed to a running terminal". Deriving the test from the
contract keeps one source of truth, so no flag can drift from the conformance. Counting terminal panes as capable
would make a script folder open create a pane, which UTERM-004 forbids. Placing beside the capable terminal would move
the pane away from the user's origin with no reason.

### Loopback and private addresses from remote output

"Terminal links from remote output" opens web URLs from remote output. A loopback, link-local, or private address
printed on a remote host resolves on this Mac instead, with the user's cookies. That is right under an `ssh -L`
forward and wrong otherwise. Open: what a click on such a URL does on remote-marked output.

Decision: a hover notice. On remote-marked output, Cmd-hover on a URL whose host is `localhost`, or a loopback,
link-local, or private-range literal, says the address resolves on this Mac. The click still opens it. The host is
classified as WebKit parses it, not from the raw text.

Leaves undone: a hostname that resolves to a local address, or a DNS rebinding, gets no notice. A remote client
UTERM-015 does not mark gets no notice either. WebKit does not expose the resolved address, and resolving on hover
would send a lookup the remote side can see.

Rationale: it names the one way a remote web URL differs, while keeping the `ssh -L` case working. Refusing would break
the forwarded case the question calls correct. Under UTERM-015's whole-pane marker it would also refuse local
`localhost` links after any `ssh` in the pane. Asking repeats what hover showed, the same as the rejected ask in
"Terminal links from remote output".

## Design Decisions (Open)

None.

## Risks

- **A document's author can trigger authenticated requests** — likelihood: low, impact: medium. A clicked link in a
  document opens in the shared browser session, so a one-click confirm link runs as the user.
  Accepted: this is the same exposure as a regular browser. A link in a PDF opened in Preview, or on any web page,
  reaches the default browser with the user's cookies too. A relaunch fetches a link-opened tab again when it is
  restored selected, the same as any tab. UTERM-005 accepted that in its risk that restore repeats a side-effecting GET.
  Script and controller opens reach only browser panes the requester created, under browser navigation. A terminal
  click on a remote web URL opens only after Cmd-hover has shown its target.
- **Replacing a viewer's document surprises the user** — likelihood: medium, impact: low. A file opened from Finder
  may replace what a nearby viewer showed. Mitigation: the replaced document stays reopenable through the window's
  close ledger, a dirty map viewer still asks before discarding, and the walk only replaces in a pane of the applet
  the router resolves for that file.
- **A batch fragments the user's working window** — likelihood: medium, impact: low. Leftovers now split the origin
  window, so ten images and one viewer split it nine times. Accepted: the user chose the files, the panes close in one
  step each, and a batch above 10 files still asks first, naming how many open new panes.
- **A remote URL resolves on this Mac** — likelihood: low, impact: medium. A remote program can print a link to a
  local service, and the click sends it with the user's cookies. Mitigation: Cmd-hover shows the target and says a
  loopback, link-local, or private address resolves on this Mac. Accepted for the rest: a hostname that resolves
  locally gets no notice, since WebKit does not expose the resolved address.
- **Prerequisites are unbuilt and may shift** — likelihood: medium, impact: medium. M4 rests on UTERM-015 M6's hover
  and remote marker. M5 rests on UTERM-004 M6, UTERM-005 M8, and UTERM-015 M4. Mitigation: each milestone names what it
  starts after. A change to those designs reaches this proposal when the milestone starts.
- **Other proposals' settled rules drift from this one** — likelihood: medium, impact: medium. This proposal amends
  UTERM-004's tie rule, UTERM-015's batch placement and remote-marker rule, and UTERM-013's Reopen, and the review edits
  none of those files. Mitigation: each milestone that changes another proposal's rule has a check that the other
  proposal records the change.
- **UTERM-015's placement tests and behavior change** — likelihood: high, impact: medium. Its routed-pane placement is
  built and tested. Mitigation: a milestone amends UTERM-015 and moves its placement tests to the walk, in one change.
- **The capability contract becomes a cross-applet contract** — likelihood: high, impact: medium. Every applet, and
  every later one, declares what it opens. Mitigation: the contract builds on UTERM-015's type declarations, which
  applets already make. It is static data, so a catalog test catches two applets claiming one scheme or type at the
  same rank.
- **Script and controller opens widen the control surface** — likelihood: medium, impact: high. Opening content in a
  pane is a new effect. Mitigation: it adds no power. URL opens use UTERM-005's browser navigation and file opens use
  UTERM-015's path-reading power, and the walk filters by the requester's authority before distance, so an open
  never lands in a pane the user made.

## Milestones

### M1: The walk and the capability contract

**Status:** NOT STARTED

- Each applet declares what it opens, and the walk checks the origin pane first, then the window's other panes in
  order of distance, without asking any pane
- The walk is tested with fixture applets and fixture pane trees, with no production viewer
- With no capable pane for a URL, the user is asked to let macOS handle the open or to cancel, and cancel does nothing
- A user open with no origin pane starts at the focused pane of the most recently key window
- The walk never chooses a pane in another window
- A pane that cannot open the target right now handles the open the way its own Open… does, and the walk never moves
  the open to a farther pane
- A `file:` URL is matched as a file, not by its scheme
- An origin pane that closes while a user open is in flight is revalidated at placement, and the open falls back to
  the no-origin anchor
- The distance metric lives in the pane model, and UTERM-004's nearest rule can call the same code
- In a flat row [A|B|C] with origin C and capable panes A and B, the open goes to B, and moving a divider never
  changes the pick
- In the tree H[A, V[O, H[C, D]]] with origin O and capable panes A and C, the open goes to C
- The tie rule reads its shared splits on the same normalized tree, with group wrappers transparent, as the metric
- UTERM-004's proposal records that its nearest rule takes this tie rule and the shared metric code
- A user open never lands in a pane inside a group a controller owns
- A file resolves its winning applet through `FileRouter` unchanged, and a saved per-type choice is honored even when
  a pane of another applet is nearer

### M2: Links from the text viewer and the browser

**Status:** NOT STARTED

- A web link clicked in a PDF, an RTF or Word document, or Markdown opens as a new tab in the nearest browser pane in
  the window
- With no browser pane in the window, the user is asked, and macOS opens the link in the default browser
- A Cmd-click on a link in a browser pane opens a new tab in that same pane, whether WebKit delivers it as a new
  window or as a navigation carrying the command modifier
- A Cmd-click counts only with a real mouse-up, under the browser's existing gesture gate
- The browser's non-web scheme hand-offs go through the walk, and still ask before opening another app
- A link opened this way uses the browser's shared website data store
- A `mailto:` link opens the mail app without asking, through the walk
- No applet holds a `URLOpening`, and every hand-off to another app goes through the router
- A document link with a scheme other than `http`, `https`, or `mailto`, and a browser link to `file:`, are still
  refused before the walk
- UTERM-007's and UTERM-005's proposals record that their link hand-offs now go through the walk

### M3: Files from Finder and File > Open

**Status:** NOT STARTED

- A file from Finder, the Dock, or Cmd-O opens in the nearest pane that opens its type, and replaces that pane's
  document
- The replaced document comes back through Reopen, in a new pane beside the pane that replaced it, whether a walk,
  the pane's own Open…, or a drop replaced it
- A replace the user cancels at a discard question records nothing, and a pane's first load records nothing
- A pane with a question already up refuses a second replace with a message, and never asks twice
- Reopen of a replaced dirty map brings back its unsaved pins, the same as pane-close undo
- When the pane that replaced the document is gone, Reopen places the old document by the no-origin anchor
- A folder routed to the terminal opens in a new terminal pane beside the origin, and no existing terminal pane is
  ever a candidate
- A catalog test checks that a file target is matched in place only in applets that replace their source, and a URL
  target in any applet that declares its scheme
- A batch waits for the batch confirmation and any type chooser to close before it splits the origin window
- Once the origin window fills, a batch's remaining files open in a new window, and a file that finds no room there
  opens in a further new window
- A pane the batch itself created never counts as an unused capable pane
- A catalog test checks that every applet declaring a URL scheme opens a URL as a new tab, not by replacing its source
- When the pane beside a replaced-document entry has no room, Reopen still places the document by the fallback, and
  never keeps the entry while building nothing
- More than 20 replaces in one viewer push older entries off the shared ledger by its stated depth, and a test pins
  which entries remain
- The map viewer captures its description for the entry after "Discard and Open" is confirmed and before its unsaved
  pins are dropped
- UTERM-013's proposal records the replaced-document entry
- Each applet's own Open… still opens in its own pane
- UTERM-015's routed-placement tests are amended to the walk, and its proposal records the change
- Three images from Finder with one image viewer in the window replace that viewer's image with the first, and open the
  other two as new panes in the same window
- The batch confirmation above 10 files says how many files replace a document and how many open new panes
- A batch asks the type chooser once for each ambiguous type
- A file whose applet has no pane in the window opens, with no prompt, in a new pane of that applet beside the origin,
  or in a new window when there is no room, a sheet is up, or no window exists
- That new pane never joins a group a controller owns
- A saved per-type choice whose applet has no pane opens a new pane of the saved applet, not of a nearer one

### M4: Terminal clicks

**Status:** NOT STARTED

Starts after UTERM-015 M6, which builds Cmd-hover, the binding to the shown target, and the remote marker.

- A Cmd-click on a web URL or OSC 8 link in a terminal pane opens through the walk
- A Cmd-click on a path opens through the walk, under UTERM-015's rules for who may open
- The open-URL action reaches the app through the terminal surface protocol, per ADR-01
- An OSC 8 `file:` link opens as a file, under the same rules as a clicked path
- An `http` or `https` URL on remote-marked output opens after Cmd-hover has shown it, and a path or any other scheme
  on remote-marked output opens nothing
- Cmd-hover on a remote-marked URL whose host is `localhost` or a loopback, link-local, or private-range literal says
  the address resolves on this Mac, and the click still opens it
- The notice classifies the host as WebKit parses it, so `0.0.0.0`, `[::1]`, IPv4-mapped IPv6, and short or numeric
  forms such as `127.1` and `2130706433` all get it, which a plain check of the URL's host string does not pass
- The terminal's own scheme filter for a Cmd-click on local output is stated and tested
- UTERM-015's proposal records the new hover notice in M6's display
- UTERM-015's proposal records that its remote-marker rule no longer refuses web URLs, and its M6 check that a web
  URL click does nothing is amended
- Cmd-hover on an `http` or `https` URL shows its real target, whatever its OSC 8 text says

### M5: Scripts and controllers

**Status:** NOT STARTED

Starts after UTERM-004 M6, UTERM-005 M8, and UTERM-015 M4, which build the permission framework, browser navigation,
and the path-reading power.

- A script or controller can ask to open a URL under browser navigation, or a file under the path-reading power
- The walk considers only panes the requester may address, and a URL open reaches only browser panes it created
- An open from a script starts at its source pane, or at the source pane the user granted an unbound caller, never at
  the focused pane
- With no capable pane the requester may address, the request fails with a structured not-found error, asks nothing,
  and hands nothing to macOS
- A request without the power is refused before any pane is touched
- A script open of a type with several winning applets fails with the structured error and asks nothing
- A script open whose source pane closes in flight fails, and never falls back to the focused pane
- A script open never creates a pane
- A URL opened by a script into a key-focused pane opens its tab unselected, per UTERM-005
- The open request travels in a versioned schema under UTERM-004's admission, so an unsupported version is refused
  before any effect

## Decision Log

- 2026-11-08: Drafted after the UTERM-007 hand check, where a PDF's web link opened the system browser. The user asked
  for cross-applet link routing as its own proposal.
- 2026-11-08: Settled with the user while drafting: one walk from the origin pane to the nearest capable pane; all four
  sources; files from Finder and Cmd-O follow it, and pane-local Open… stays; with no origin, start at the frontmost
  window's focused pane; stay in the window; ask macOS-or-cancel when nothing opens; take a fixed pick for ties; use
  the shared browser session for document links; keep a replaced document reopenable.
- 2026-11-08: Review start: 5 milestones, 7 settled decisions, 5 risks, no `**Live after:**` lines or row gates; out
  of scope: pane-local Open… stays in its own pane, and the walk never leaves the window. The user asked for an
  autonomous review of the 10 open questions, from the commit "Rate UTERM-018's link session risk the same as a
  regular browser".
- 2026-11-09: The capability contract is static only: applet type declarations gain URL schemes, and a pane that
  cannot open now handles the open as its own Open… does, never rerouting. (autonomous)
- 2026-11-09: "Nearest" is UTERM-004's shortest edge distance in the normalized pane tree, built once in the pane
  model. A geometric tie-break raised against it moves to "The tie rule". (autonomous)
- 2026-11-09: One window-level router, grown from `RoutedOpener`, owns the walk and the hand-off to macOS. Applets
  reach it through a host call and stop holding a `URLOpening`. (autonomous)
- 2026-11-09: Script and controller opens fold into UTERM-005's browser navigation and UTERM-015's path-reading power,
  and walk only panes the requester may address. A REPL script cannot open into the user's own browser pane.
  (autonomous)
- 2026-11-09: Amended three settled decisions to fit the decisions above. "One walk for every open" said the walk asks
  "the panes ever further from the origin, until it reaches the window's root", and now orders panes by edge distance.
  "An open with no origin pane" said a script with no pane starts at "the focused pane of the frontmost window", and a
  script now starts at its source pane; the user-open anchor now reads "most recently key window", matching UTERM-015.
  "No capable pane" asked the user for every open, and a script open now fails with an error instead. Focus never
  establishes authority under UTERM-004, and UTERM-004's nearest rule never falls back. (autonomous)
- 2026-11-09: Ties break by tree position: the candidate whose child index at the shared split is closest to the
  origin's wins, then reading order, then stable pane ID. UTERM-004's accepted tie rule, reading order then stable pane
  ID, takes the same rule. (autonomous)
- 2026-11-09: Rank filters first: `FileRouter` resolves the winning applet unchanged, and distance picks among its
  panes. (autonomous)
- 2026-11-09: No browser modifier skips the origin. The Motivation and M2 named Ctrl-click as a new-tab gesture, which
  on macOS opens the context menu, so both now say Cmd-click. (autonomous)
- 2026-11-09: Added the open question "How a batch walks", which the review found: UTERM-015's batch rule has no
  counterpart in the walk.
- 2026-11-09: A link-opened tab restores like any tab, by UTERM-005's rule. The first risk is now accepted on that
  basis. (autonomous)
- 2026-11-09: A batch walks file by file, each taking an unused capable pane, with leftovers split into the origin
  window. (autonomous)
- 2026-11-09: A web URL on remote terminal output opens after Cmd-hover shows it. Paths and other schemes stay
  refused. This amends UTERM-015's remote-marker rule for web URLs only. (autonomous)
- 2026-11-09: A file with no capable pane opens in a new pane beside the origin, with no prompt. This amends the
  settled "No capable pane", which asked macOS-or-cancel for every open, and the Summary and M1 check that said so.
  macOS loops back to uniterm when it is the file's default app, and a prompt would contradict the batch rule.
  (autonomous)
- 2026-11-09: "How a batch walks" no longer counts the no-capable-pane prompt among a batch's prompts, since files
  have none. (autonomous)
- 2026-11-09: Coherence fixes. "The tie rule" compared child indices only, which is undefined when tied candidates
  share different splits; a deeper shared split now wins first. "Rank versus distance" said schemes "resolve the same
  way" as files, and now resolve by rank alone, since nothing writes a saved scheme choice. "How a batch walks" placed
  a file with no capable pane beside the origin and leftovers in the largest pane; both now split the largest pane,
  and a batch spans at most two windows. "One walk for every open" now says each source's own filter runs first.
  "No capable pane" now carves out `mailto:`. (autonomous)
- 2026-11-09: Tagged as additions the changes to other proposals' settled rules: UTERM-004's tie rule, UTERM-015's
  batch placement and remote-marker rule, and Reopen for a replaced document in UTERM-013. (autonomous, addition)
- 2026-11-09: Added three open questions the coherence review found: how Reopen restores a replaced document, what
  "capable" means for an applet whose open makes a new pane, and what a remote loopback or private-address URL does.
- 2026-11-09: A replace reports its commit to the host, and the window ledger keeps the old document for Reopen, which
  restores it in a new pane. It covers every replace, including a pane's own Open… and drops, beyond the walk opens the
  settled text named. The menu title stays. (autonomous, addition)
- 2026-11-09: Only applets that replace their source are capable in place, so a terminal pane is never a target.
  "What a pane does with an open" said a terminal pane "opens it the way UTERM-015 already defines", and now says the
  terminal opens a folder in a new pane. (autonomous)
- 2026-11-09: A remote-marked loopback or private-address URL gets a hover notice and still opens. M4's check said
  only "loopback or link-local", and now matches the decision. It adds a hover notice to UTERM-015 M6's display and a
  host classifier. (autonomous, addition)
- 2026-11-09: Re-check fixes. "Applets whose open makes a new pane" gated every target on replacing a source, which
  would exclude the browser from URL opens; the gate now applies to file targets only. "How a batch walks" claimed "a
  batch spans at most two windows", which fails once a second window fills; overflow now chains to further windows,
  as UTERM-015 settles. (autonomous)
- 2026-11-09: The proposal loop converged after three passes: the full pass, then two re-checks.
- 2026-11-09: Risk review. Added four risks: batch fragmentation, accepted; remote URLs that resolve locally, mitigated
  by the hover notice with the DNS gap accepted; unbuilt prerequisites, mitigated by starts-after lines; drift in other
  proposals, mitigated by record checks. Updated the replace and control-surface mitigations to the settled design. No
  risk is high likelihood and high impact. No decision is a one-way door: declarations are in-process, the browser
  description gains no field, and a redeploy reverts every change. (autonomous)
- 2026-11-09: Review gate: kept all. The user kept every amendment to their settled decisions and every addition,
  after asking when a terminal is a target today and what Reopen covering every replace means.
- 2026-11-09: ADR candidate (departs from the past): an applet never decides where content it opens goes; the window
  chooses the pane or app. Declined: the user chose to keep it in this proposal.
- 2026-11-09: Accepted by the user.

## References

- ADR-01: libghostty is reached only through the terminal surface protocol
- ADR-02: panes are addressed by stable ID
- ADR-03: restored state never runs a program the user did not ask for
- ADR-04: applets declare their own keys and never take window keys
- ADR-09: control authority needs an authenticated requester and an explicit, scoped grant
