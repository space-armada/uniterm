# UTERM-054: Screenshot a Pane or Tab

**Status:** accepted
**Created:** 2026-11-22
**Updated:** 2026-11-26

## Dependencies

- UTERM-004, for the control framework a program's capture is granted under
- UTERM-005, for the browser's tabs and web views
- UTERM-019, for the browser's full-page snapshot, the handle and chunked result reads, and the per-result byte cap

## Impacts

- UTERM-019 — "Full-page snapshot" and M4. The user's full-page capture uses the same route and the same clamp on pixel
  area. Whichever proposal builds it first owns the code, and the other reuses it.
- UTERM-019 — the browser capture permission, the snapshot command, and the rule that next-events is the only command
  that waits. UTERM-019 is amended before its M1 ships so one pane capture power covers every applet and the snapshot
  takes this proposal's held reply. See "How a program's capture power relates to browser capture".
- UTERM-055 — "Where a program's capture command lives" and "What an unselected tab or a hidden pane captures". Exec
  drivers reach this proposal's host capture, its reason kinds, and its tab scope through UTERM-055's exec version.
- UTERM-048 — the pane inspector lists a pane's facts. A capture of the inspector's pane is an ordinary capture, and
  the inspector needs no change.

## Summary

The user copies a screenshot of the current pane or tab to the clipboard as a PNG, or saves one to a file. Each applet
captures its own content through an optional capability, so no screen capture and no Screen Recording permission is
involved. The browser also captures a full-length page. Scripts and controllers take the same captures under a granted
power.

## Motivation

There is no way to capture a pane today. macOS's own screenshot tool needs the user to frame the pane by hand, picks up
the host's focus border and badges, and cannot see a web page past its viewport. Sharing a terminal's output, a map, or a
page as an image takes several steps and a crop.

The capture has to come from each applet. A screen capture needs Screen Recording permission. Generic AppKit view
capture renders ordinary views, but it misses content that a view does not draw itself. A web view, a map view, and the
terminal's Metal surface are all of that kind. Applied by default, it would save a blank area and report success.

No production code captures images today. The UI tests capture panes with `XCUIElement.screenshot()`, which is test-only.
UTERM-019 M4 plans a browser snapshot for controller scripts, with a handle, chunked reads, and a full-page route.

## Design Decisions (Settled)

### Each applet captures through an optional capability

Decision: capture is an optional capability sub-protocol on the applet contract, as `AppletCommandHandling` and
`TabOpening` are. The host checks for it with `as?`. An applet that does not adopt it offers no screenshot command, and
its menu items and palette entries are disabled or absent. The capability returns an image, or an error that says what
could not be captured. Capture never reads the screen, so it needs no Screen Recording permission.

Rationale: from the idea's chosen design. Each applet knows which of its views draw their own content and which do not.
ADR-05 lets each applet decide how it responds. A capability the applet lacks is unrepresentable as a command, so no
applet reports a blank capture as success.

### AppKit view capture is an opt-in helper

Decision: a shared helper renders an AppKit view hierarchy into a bitmap, through `bitmapImageRepForCachingDisplay` and
`cacheDisplay`. An applet calls it for views it knows draw themselves. It is never the default for an applet that does
not adopt the capability. An applet whose view mixes kinds, such as a toolbar over a web view, composites its own parts.

Rationale: from the idea's chosen design. The helper would save a blank area for a web view, map view, or Metal layer.
Making it opt-in keeps that failure out of every applet that did not check.

### A tab is its content; a pane is the applet's view

Decision: a tab screenshot is the selected tab's content alone, without the tab bar or toolbar. A pane screenshot is the
whole applet view, including the applet's own tab bar and toolbar. Both leave out what the host draws around and above
the applet: the gutter, the focus border, the control and asking badges, and the exec strip. The window's status bar
belongs to the window and is never part of a pane.

Rationale: from the idea's chosen design. The host places its frame and overlays as siblings of the applet view, so
capturing the applet view already leaves them out. The user's screenshot then shows what the applet shows, with no host
state in it.

### Copy and save are separate commands

Decision: the user gets Copy Screenshot, which puts a PNG on the general pasteboard, and Save Screenshot As…, which opens
a save panel for a PNG file. The save writes atomically off the main thread, through the map viewer's Save As route: a
uniquely named temp file beside the target, swapped in with `replaceItemAt`. A failed write raises an alert that names
the file and keeps the earlier one.

Rationale: the user chose both. Copy serves pasting into a chat or a document. Save serves keeping a file.

### The browser captures the viewport, and offers a full page

Decision: the browser's tab and pane screenshots capture the visible viewport through `WKWebView.takeSnapshot`. A
separate full-page command captures the whole document, through UTERM-019's "Full-page snapshot" route: `takeSnapshot`
with a rect covering the content size, or rasterized `createPDF` output when WebKit leaves the off-screen part blank. The
pixel area is clamped before rendering, as UTERM-019 settles. The full-page command exists only for the browser, and
captures the tab's content without chrome.

Rationale: the user chose this. The plain command matches every other applet. A full-length page is the one capture the
macOS tool cannot take. Reusing UTERM-019's route keeps one full-page implementation and one clamp.

### Capture never blocks the main thread

Decision: a capture starts on the main thread and returns. View rendering and WebKit's completion handlers run on the
main thread, as AppKit and WebKit require. PNG encoding and the file write run off it. While a capture is pending, the
pane shows a pending state, and a second capture of the same pane is refused until it finishes. A program's pending
capture never refuses the user's own capture of that pane, under ADR-14 P15. A capture has a time bound, and its
pending state can be cancelled. A capture that fails or times out posts a status notice that names the pane and the
reason. The notice is non-modal, so it never takes focus. A failed save keeps its alert, since the user chose the file.
Taking a screenshot never moves focus. Amended 2026-11-22; see Decision Log.

Rationale: ADR-08. A full-page snapshot and a large PNG encode take time uniterm does not bound. ADR-07 keeps a failed
capture to that pane.

### Scripts and controllers capture too

Decision: a script or controller can capture a pane or tab of any applet that has the capability, and the browser's full
page. A capture needs an authenticated requester and an explicit, revocable grant under ADR-14 P7. The grant names the
operation, its targets, and a bound under ADR-14 P15. The reply follows ADR-11, and "Where a program's capture command
lives" settles its shape: a held reply that returns a result handle, since a capture only reads. Retained results are
capped per result and per run. A capture behaves as the user's command does, under ADR-15, except for authority.
Amended 2026-11-22; see Decision Log.

Out of scope: a program never copies a capture to the clipboard, since the clipboard-write power writes plain text
only. The ideas file keeps it as "Scripting: write images and other types to the clipboard". External exec drivers
capture under UTERM-055, not here.

Rationale: the user added this to the scope. One capture path serves the user and programs, so the two cannot drift.

### Version skew

Decision: the deploy units are the app, external exec drivers, native controller executables, controller descriptors,
and the controller policy file. The Janet helper ships with the app's side of ScriptWire in the app bundle, so the
two are not skewed. A newer user script on an older app gets an unbound-symbol error.

- Native controllers: a native controller entry opens its own ScriptWire connection from outside the bundle, and
  ScriptWire's hello accepts only the app's exact version. The capture calls change ScriptWire, so a native controller
  built against the earlier version is refused at hello, and a newer one is refused by an older app. Every ScriptWire
  change does this today. Filed as
  [20261122-native-controller-refused-after-scriptwire-change](../bugs/20261122-native-controller-refused-after-scriptwire-change.md),
  which names the conflict with ADR-13. Accepted until UTERM-056 lands, since this proposal makes no ScriptWire change
  that others do not. After that, a native controller at version 14 or later keeps running, and only lacks the capture
  calls. Amended 2026-11-23; see Decision Log.

- Exec drivers: this proposal changes no exec frame or version, so a driver on either side sees no difference.
  UTERM-055 adds exec capture in its own version. Amended 2026-11-22; see Decision Log.
- New descriptor, old app: a descriptor that names the capture power is refused at load, as UTERM-004 format 2 refuses
  every unknown kind. A controller that needs capture states it, and runs only on an app that knows it.
- Old descriptor, new app: a descriptor without the capture power gets none. A grant stored before the power existed
  covers none of it, under ADR-14 P10.
- New policy file, old app: once the user approves the capture power, the policy file holds a kind the older app lacks.
  An older uniterm then loads no policies, marks the file read-only, and remembers no trust until the user upgrades.
  This is UTERM-004's designed behavior for every new kind, and UTERM-019 states the same direction. Accepted.

### How the terminal captures

Original question:

libghostty v1.4.0 has no call that reads back the rendered frame. It installs its own layer on the view uniterm passes
it, so the AppKit helper will likely capture a blank area. It can read back the screen's text, as the accessibility value
already does. Candidates:

- Read the surface's layer contents. If the layer is IOSurface-backed, copy the IOSurface into a bitmap. Needs a spike
  on the pinned build. Reaches into a layer libghostty owns, so the read stays inside the terminal surface module behind
  a protocol addition, per ADR-01. Leaves undone: a libghostty upgrade can change the layer silently.
  The renderer thread may write the surface while uniterm reads it, so a read can tear unless it locks the surface. An
  occluded or minimized view may hold a stale frame.
- Add a readback call to libghostty as a local patch, beside the three in `ThirdParty/ghostty-patches/`. Draws the
  frame into a caller's buffer on the renderer's terms. Adds patch upkeep on every upgrade.
- The same patch, also sent upstream, so the upkeep ends once a release carries it.
- Render the screen's text and styles into an image in uniterm. Loses images drawn by the terminal, ligatures, and the
  exact font rendering, so it is not a screenshot of what the user sees.
- The terminal and REPL do not adopt the capability. Leaves undone: the most common pane gets no screenshot.

Decision: a local libghostty patch adds a capture call that draws the surface's current frame into a caller's buffer on
the renderer's terms. It runs the cell update under the renderer's state mutex before it draws, so a terminal whose
output changed while hidden captures its current cells. It holds the draw mutex while drawing, so no swap-chain reuse
can tear it. It completes on the render thread through a callback, so the main thread never waits on the GPU. The patch
sits beside the others in `ThirdParty/ghostty-patches/`, and the call stays inside the terminal surface module behind a
protocol addition, per ADR-01. M4 opens by building the patch on the pinned build and checking that it produces the frame.
(autonomous)

- Offering the patch upstream is a separate act that publishes code. It needs the user's go-ahead, and the design does
  not count on the upkeep ending. ADR-01's context notes that Ghostty steers outside embedders to libghostty-vt.
- The pinned source shows why the other routes fall short. libghostty makes the view layer-hosting with its own
  IOSurface layer, so the view draws nothing for `cacheDisplay`. While hidden, it frees its swap chain and skips the cell
  update, so the layer keeps the last frame. The renderer takes no IOSurface lock, so a raw layer read can tear.

Leaves undone: patch upkeep on every libghostty upgrade, until upstream carries an equivalent call.

Rationale: the patch is the only route that gives the current frame for a showing or hidden terminal without tearing
and without blocking the main thread. The public `ghostty_surface_draw` plus a layer read needs no patch. But it still
reads a layer libghostty owns, and it gives a stale frame or an error for a hidden pane. Rendering text from
`read_text` reports success with an image unlike the screen. Converged in 1 pass.

### How a program's capture power relates to browser capture

Original question:

UTERM-019 adds a typed "browser capture" permission for a controller's own browser tabs. It also covers PDF output and
find in page. It has not shipped, so no descriptor names it yet. Candidates:

- One pane capture power covers every applet. UTERM-019 is amended before its M1 ships, since M1 creates the browser
  capture kind. Browser capture then never exists as a separate kind. The amendment says where PDF output and find in
  page go.
- One pane capture power covers every applet, and UTERM-019 M1 ships browser capture first. A grant stored for browser
  capture must not carry over to other applets, under ADR-14 P10, so the user approves the new power again.
- A new pane capture power for every applet besides the browser, and browser capture stays as UTERM-019 defines it.
  Two powers for one operation.
- A per-applet capture power. More review text, finer grants.

Every candidate names the power's bound under ADR-14 P15.

Decision: one pane capture power covers every applet. UTERM-019 is amended in place before its M1 ships, so browser
capture never exists as a separate kind. The amendment moves the browser snapshot under this power and this proposal's
reply shape, and changes UTERM-019's rule that next-events is the only command that waits. `:browser/snapshot` leaves UTERM-019's
capability set, since the host capture takes both the viewport and the full page. PDF output and find in page stay
browser commands under the pane capture power. Amended 2026-11-22; see Decision Log. If UTERM-019 M1 ships first, browser capture is widened to every
applet under a version 2 of the same kind. An approval under version 1 then covers only the browser, under ADR-14 P10.
(autonomous)

- The power's bound under ADR-14 P15 is its targets, settled in "Which panes a program may capture", plus the result
  caps per result and per run, one pending capture per pane, and the time bound.

Rationale: one operation gets one kind and one review text, and no stored grant needs approving again. Keeping browser
capture beside a new power gives two kinds for one operation. Shipping browser capture and then dropping it would refuse
every descriptor that names it at load. A per-applet power adds a kind and a descriptor change for every capable applet.
Converged in 1 pass.

### Which panes a program may capture

Original question:

A screenshot reads content the user sees, which can include other programs' panes and the user's own work. One pane can
mix owners. A browser pane holds the user's tabs beside a controller's, and UTERM-019 limits every browser command to
tabs the controller opened. A questions pane holds up to 8 requesters' tabs, with any answer the user has typed so far.
`ControlDispatcher` already refuses a command without authority over the pane. Candidates:

- Panes among the program's targets under ADR-14 P1 to P3, plus owner-level scope where a pane mixes owners. A tab
  capture needs the tab to be the program's own, and a pane capture of a mixed pane is refused.
- Panes among the program's targets, with no tab-level scope. Leaves undone: a controller reads the user's selected
  browser tab and another requester's form, which reopens UTERM-019's settled scope.
- Panes the program targets unattended, and any other pane only after the user confirms each capture. One-use consent
  is the bound.
- Any pane, under the capture power alone, with review text that says so. Names no target bound, against ADR-14 P7 and
  P15.

Decision: every tab whose content or title the image shows must be within the program's tab scope. A tab capture shows
the selected tab. A pane capture also shows every title in the tab bar. The tab scope is the tabs the program opened,
plus the source tab it acts for under ADR-14 P2. A driver's own pane counts as wholly its own, since a driver attaches
to the pane, not a tab. For an applet with no per-tab owners, a pane among the program's targets counts as wholly its
own. Once UTERM-062 gives the viewers per-tab owners, a group pane's tab scope in a viewer is the tabs the program owns.
Amended 2026-11-26; see Decision Log. The terminal has per-tab owners: see "A program's tab scope in a terminal
pane". Amended 2026-11-22; see Decision Log. Only the applet knows its tabs' owners, so the capture capability takes the caller and
applies the rule. (autonomous)

- A capture of the source pane gives a program what no other power gives: the user's visible terminal output, including
  earlier commands' output. The capture power's review text says so.

Rationale: the rule keys on ownership, not on whether a pane mixes owners. A rule keyed on mixing lets a program capture
a pane whose tabs are all the user's, which UTERM-019's settled scope forbids for snapshots. It also refuses a script's
capture of its own source tab. Confirming every capture is the "ask for every effect" pattern ADR-14 rejects. Any pane
under the power alone names no target bound, against ADR-14 P7 and P15. Converged in 1 pass.

### Where a program's capture command lives

Original question:

Everything the program decision borrows from UTERM-019 is scoped to a browser tab: its commands are named per applet
type, its event buffer is per tab, and its handle cap is per tab. A terminal pane has none of these. Candidates:

- A host-level pane command, such as `capture-pane`, that works for every capable applet. The handle lives on the pane.
  One command name, one schema. Remote callers receive no applet events under UTERM-004, and exec drivers get events
  only from the pane they drive. So this candidate names its carrier for the completion event: a new push stream, or a
  host-level next-events buffer. The push stream adds scope: it amends UTERM-004's "remote callers receive no applet
  events" and the exec and remote wires.
- A capture that only reads holds a pending reply under ADR-11, and the reply carries the handle once the PNG is ready.
  No completion event is needed. A capture that also copies to the clipboard has an effect, so it keeps the
  handle-plus-event shape.
- Per-applet commands, such as `:terminal/capture`, each added to that applet's command schema with a schema minor bump.
  Each applet then needs its own handle slot and event delivery, which the terminal lacks.
- The browser keeps UTERM-019's per-tab snapshot, and every other applet uses a host-level command. Two shapes for one
  operation.

Every candidate rides the existing `command` or `paneCommand` frame, or waits for UTERM-028's version negotiation. See
"Version skew". The PNG bytes read back in chunks under a byte type. UTERM-019's "Result encoding" defines that type,
and it has not been built.

Decision: capture is a host-level operation. The host owns the steps "Capture never blocks the main thread" gives it:
the pending state, the time bound, cancel, the one-capture-per-pane rule, and PNG encoding. It calls the applet's
capability with the caller.

- Scripts and descriptor controllers reach it through new ScriptWire calls: capture, read-result, and discard. The
  Janet helper ships with ScriptWire in the app bundle. A native controller does not; see "Version skew". A capture only reads, so its reply holds until the PNG is ready,
  under ADR-11, and returns a result handle. The bytes read back in chunks under the byte type that UTERM-019's "Result
  encoding" adds. The pending path re-checks authority at completion, as `formResult` does, and a result that fails the
  re-check frees its slot.
- External exec drivers capture under UTERM-055, which adds an exec protocol version. This proposal adds no exec frame. Amended 2026-11-22; see Decision Log.

Rationale: one host path serves the user and programs, as "Scripts and controllers capture too" requires. Per-applet
commands would copy the host's steps into each applet's schema, and a script that captures any pane would switch on
applet type and schema version. An event stream or buffer is not needed for a command that only reads. A reserved host
applet type would be a special case inside a dispatcher check that keys on the pane's applet. Converged in 1 pass.

### Which commands the user sees

Original question:

A tab capture leaves out the applet's tab bar and toolbar, so a tab and a pane differ in any applet with chrome. The map
viewer has a pin list, and the text viewer has a find bar and a contents sidebar. The terminal hides its tab bar below
two tabs, so a single-tab terminal gives the same image for both. Candidates:

- Four commands for every capable applet: Copy and Save for each of tab and pane, with no hiding rule. A tab and a pane
  may give the same image.
- Two commands, Copy and Save, that capture the pane, plus tab variants only where the applet has a tab bar.
- Tab variants that follow whether the tab bar shows, so a single-tab terminal offers only the pane pair.
- Two commands that capture the tab, with the pane variant in the palette only.

Whichever is chosen, each applet's milestone states what its tab content is.

The browser's full page adds a Copy and a Save of its own under each candidate.

Decision: every capable applet offers four commands with fixed titles: Copy Screenshot and Save Screenshot As… for the
content, and Copy Pane Screenshot and Save Pane Screenshot As… for the applet view. The browser adds Copy Full Page
Screenshot and Save Full Page Screenshot As…. No command hides or changes its title with the tab count or with toggled
chrome. In an applet whose content and view are the same image, both pairs still show. (autonomous)

Rationale: availability never changes with state, and a fixed title keeps the user's App Shortcuts remaps working,
since UTERM-013 binds by title. Every capture a program can take has a user command, as ADR-15 asks. The titles read
correctly in applets that have no tabs. Showing tab variants only with a tab bar would leave the map viewer without a
map-only capture that programs still have. Following the tab bar's visibility would hide the browser's content capture
in a one-tab pane, where the toolbar still differs. Converged in 1 pass.

### What an unselected tab or a hidden pane captures

Original question:

The user always captures the selected tab of a showing pane. A program can name an unselected tab, a pane in a
background window, or a pane whose window is minimized. A web view not in a window may have nothing current to render,
and the terminal may have no current frame. Candidates:

- Capture what the applet can render, and return a structured error that names the reason when it cannot. Each
  applet's milestone records which cases work.
- Refuse every capture that is not of a selected tab in a showing pane.
- A program's capture always takes the pane's selected tab, as the user's command does. A program that wants another tab
  selects it first with the existing select command, under pane control. Leaves undone: in a browser pane that mixes
  owners, that select switches the tab the user is looking at.
- Make the tab show itself before the capture. One call then silently does two operations, a select and a capture.

UTERM-019 M4 requires a snapshot of an unselected tab or a tab in a detached pane to work or return a structured error.
The answer here must agree with it. A stale frame that reports success is a risk under every candidate.

Decision: an applet captures a target state only when its milestone proved that state. Every other state returns a
structured error that names the reason: an unselected tab, a pane in a background window, or a minimized window's pane.
The applet never tries a render whose result it cannot trust. The reason kinds are append-only names that programs can
switch on. (autonomous)

Rationale: this keeps the terminal patch's hidden-terminal frame where the milestone proves it, agrees with UTERM-019
M4, and never reports a stale frame as success. Refusing every hidden capture would leave that part of the patch with no
caller. A select-first rule rests on a select command that only the browser has. Selecting inside the capture would
give the held reply an effect, which ADR-11 forbids, and it would move what the user sees. Converged in 1 pass.

### How a program saves a file

Original question:

Candidates:

- The program reads the bytes under the handle, and writes them with its own file access. uniterm writes nothing on its
  behalf.
- A `save-screenshot` command shows the user's save panel, as UTERM-049's `save-tabs` does. The user's pick authorizes
  the write. A program-raised panel needs a P15 bound on how often it claims the user's attention.
- Both.

Decision: the program reads the PNG bytes under its result handle and writes them with its own file access, such as a
script granted `fs-write`. uniterm writes nothing on a program's behalf. (autonomous)

Leaves undone: a program without file-write access cannot save a capture. A program's own write shows no Replace
confirmation, which its file-write grant already accepts.

Rationale: the settled read-back already gives a program the bytes, so this adds no contract. A program-raised save
panel would be a new published command. It would need the capture power and the tab-scope check, a P15 bound on how
often it claims the user's attention, and a reply that settles before the write under ADR-11. No caller needs it.
Converged in 1 pass.

### How the map viewer captures

Original question:

`MKMapView` draws its tiles in its own layers, so the AppKit helper may capture blank tiles. Candidates:

- `MKMapSnapshotter` with the view's region, camera, and size, plus the pins drawn over it. Re-renders the map, which
  may fetch tiles over the network and fail offline. Its image can differ from the screen, and it needs its own pin
  drawing.
- AppKit view capture, if a check shows it renders the tiles on the oldest supported macOS.
- The map viewer does not adopt the capability.

The pin list is plain AppKit and captures through the helper either way.

Decision: M3 opens by checking the AppKit view-capture helper on the map view, on macOS 26. If it renders the tiles,
the map captures through it. If not, the map captures through `MKMapSnapshotter` with the view's region, camera, size,
and configuration. Either way, the pins come from the live marker views, drawn over the image at their converted points
with the AppKit helper, so no second pin renderer exists. A snapshot that cannot get its tiles, such as offline with none
cached, returns a structured error. The pin list captures through the helper. (autonomous)

Rationale: the view capture is exact, current, and works offline when it renders the tiles. The snapshotter is the
route when it does not. Reusing the live marker views keeps a later marker style change in every screenshot. uniterm
supports macOS 26 only, so the check runs once. Converged in 1 pass.

### Output scale, name, and place

Original question:

- Scale: the window's backing scale, so a Retina screen gives a 2x image, or always 1x.
- Default file name: the pane's title with a timestamp, as macOS screenshots are named, or a fixed name.
- Default folder: the system screenshot folder, the last folder used, or Desktop.

Decision: (autonomous)

- Scale: the window's backing scale, so a Retina screen gives a 2x image. The PNG records its density, 144 dpi at 2x,
  as macOS screenshots do, so it pastes at its on-screen size.
- Name: the captured title plus a timestamp, such as "user@host - ~-src 2026-11-22 at 10.15.30.png". A tab capture uses
  the tab's title, a pane capture the pane's, and a full-page capture the page's. The title is made safe for a file
  name: `/` and `:` are replaced, control characters are stripped, leading dots are dropped, and the length is capped in
  bytes with room for the timestamp and `.png`. An empty title falls back to the applet's name.
- Folder: the system screenshot folder, read from the `location` key of the `com.apple.screencapture` preferences
  domain. A missing value, a `~` path that does not expand to a folder, or a folder that no longer exists falls back to
  Desktop. The `target` key, which macOS uses for Save to Clipboard, is ignored.

Rationale: backing scale is what every route produces with no extra step, and it keeps terminal text sharp. A 1x image
would add a lossy downsample to every route. The title makes a file easy to find later, and the timestamp keeps a
second save from landing on a Replace prompt. The screenshot folder follows a setting the user made in Screenshot.app,
where their other screenshots already go. AppKit's last-used folder would carry hidden state over from an unrelated
save, such as a GeoJSON file in a project folder. A remembered screenshot folder would add a persisted path that can go
stale. Converged in 1 pass.

### A default shortcut

Original question:

Candidates: no default key, reached through the menu and palette and bindable in App Shortcuts, as UTERM-049's Save
Tabs As is. Or a window key under ADR-04, reserved so no page or terminal can take it. A key reserved for every pane
takes it from every web page and terminal program.

Decision: no default key. The menu and the palette reach the screenshot commands, and the user binds a key by title in
App Shortcuts, which UTERM-013 lets win. (autonomous)

Leaves undone: keyboard users reach the commands through the palette or a remap.

Rationale: the window offers an enabled menu item's key to the menu before any view sees it, so any default key would
be taken from every web page and terminal program in a capable pane. A reserved key would also do nothing in a pane
that cannot capture, and still never reach the view. macOS already claims the usual screenshot keys. UTERM-049's Save
Tabs As sets the same precedent. Converged in 1 pass.

### A program's tab scope in a terminal pane

Original question: the terminal adopts `TabOpening` but not `CallerOwning`, and programs open terminal tabs with no
owner recorded. Under "an applet without per-tab owners counts as wholly its own", a script in tab 1 could capture the
user's sibling tab 2, such as an ssh session. Should the terminal record per-tab owners, keep pane-wide reach and state
it, or allow only the selected source tab?

Decision: the terminal records each tab's owner: the run that opened it, or the user. It adopts `CallerOwning`, so the
first tab of a terminal pane a controller's layout opened is the controller's, and a grant's end releases its tabs. The
source tab comes from the tab whose session the binding's root belongs to. The terminal's session start already names
its tab, and the host keeps that tab beside the root it records for the pane. The capture capability's caller carries
the source tab. A capture then follows the tab-scope rule, so a sibling user tab is refused. The REPL has one fixed tab,
so it records nothing new and its one tab is its pane. (autonomous)

Leaves undone: a terminal pane the user enables for a controller holds only the user's tabs, so the controller cannot
capture it. The browser behaves the same way. A user who wants a controller to screenshot a terminal runs the program
from that tab.

Rationale: this is the only option that meets the settled tab scope: the tabs a program opened plus its source tab.
It follows the browser's owner pattern. Stating pane-wide reach in review text would keep a read of the user's ssh
session. Allowing only the selected source tab refuses the program's own tabs and keys on tab count. Converged in 1
pass.

### What a program's capture shows the user

Original question: a capture that fails or times out raises a notice and a pending state on the pane, and a program's
capture behaves as the user's. Programs get structured errors by design, so a retrying controller could raise a notice
per attempt. Should a program's capture show nothing, show only the pending state, or show both under a bound?

Decision: (autonomous)

- A refusal decided before the capture starts goes in the reply only, as every program refusal does today. That covers
  authority, tab scope, and the target states an applet did not prove. Nothing is pending, so nothing shows.
- A capture that runs shows the same pending state and cancel as the user's.
- Its failure posts the user's notice, naming the pane and the requester. A run posts at most one capture-failure notice
  per pane. Later failures in that run go in their replies only, under ADR-14 P15.

Rationale: one behavior per action, as ADR-15 asks, with the attention bound P15 requires. Hiding a program's capture
would leave the user no way to cancel it, and would hide a read of the user's pane. Withholding only the failure would
make what the user sees depend on who asked. Converged in 1 pass.

### What a program's capture shows of a file the program may not read

Original question:

The tab-scope rule in "Which panes a program may capture" counts a program's source tab as its own. It checks no file
read scope. An applet that shows a user-opened file can therefore hand a program, in pixels, what its own contract
withholds. Filed as
[20261122-capture-bypasses-image-viewer-read-scope](../bugs/20261122-capture-bypasses-image-viewer-read-scope.md).

Two applets state such a contract in code:

- The image viewer's replies and events carry an image's path only when the caller's scope holds both the source and
  the image's real path. A script in the image viewer pane, holding the capture power and no path-read power, could
  capture the user's image.
- The map viewer's `pin-selected` event gives a pin from the user's file only its source, and no ID, coordinate, or
  other value from the file. A capture of the map pane shows those pins at their positions, and the pin list shows
  their names.

The text viewer and the data viewer also show user-opened files. Neither states a withholding contract today.

UTERM-055 gives exec drivers a caller with no read scope, so whatever this question settles applies to drivers as
written. UTERM-055 M1 waits for it.

Candidates:

- A capture is refused with a named reason when the image would show a file the caller's read scope does not hold, as
  the viewer's replies withhold its path. The reason joins the append-only reason kinds.
- The capture power's review text states that a capture reads whatever a pane shows, including files the program may
  not read. The image viewer's and the map viewer's contracts narrow to paths, listings, and event values. Leaves
  undone: a program granted capture reads every user-opened file in its source pane.

Sub-questions that follow from the first candidate:

- Which applets the rule covers: the image viewer, the text viewer's plain text, PDF, and Markdown, the data viewer, and
  the map viewer's file layer.
- For the map viewer: whether the capture is refused while the file layer shows, or the file layer and its pin list
  rows are left out of the image.
- Once UTERM-062 gives the viewers tabs: whether a pane capture's tab bar shows the titles of tabs whose files the
  caller may not read. UTERM-062 checks read scope per tab for titles, so a title the caller may not read is withheld
  everywhere else.

Decision: a capture never shows a file the caller may not read. Where only part of the image comes from such a file,
that part is left out. Where the pane's content is such a file, the capture is refused with a named reason. The user
chose this on 2026-11-26, over refusing every such capture and over allowing it with review text that says so.

- The image viewer, the text viewer's plain text, PDF, and Markdown, and the data viewer refuse a capture whose content
  is a user-opened file outside the caller's read scope. The reason joins the append-only reason kinds.
- The map viewer captures without the file layer and without its rows in the pin list when the caller may not read the
  map's file. A program's own pins still show.
- Once UTERM-062 gives the viewers tabs, a pane capture's tab bar shows no title for a tab whose file the caller may not
  read, as UTERM-062 withholds that title everywhere else.
- The check uses the caller's read scope, the same one the viewer's replies and events use, so a capture and a reply
  never disagree about what a program may see. An exec driver's caller holds no read scope, so it applies to drivers
  as written.

Rationale: uniterm already promises that a program learns nothing about a user's file outside its read scope. A capture
that hands over the pixels would break that promise for any program with the capture power. Leaving out only the
unreadable part keeps the useful captures: a script that adds its own pins to the user's map can still capture them.
Refusing every capture would lose that case. Allowing it would shrink the promise to paths and names, and every file
the user opens in a granted pane would reach the program.

## Design Decisions (Open)

None.

## Risks

- **A capture saves a blank or partial image and reports success** — likelihood: medium, impact: medium.
  Mitigation: capture is opt-in per applet, and each applet's milestone checks its image against what is on screen,
  including web, map, and Metal content.
- **The terminal route depends on libghostty's internals** — likelihood: high, impact: medium.
  Mitigation: M4 opens by building the capture patch on the pinned build and checking its frame. On an upgrade, the
  failure mode is a patch that no longer applies, which the build catches. The call stays behind the terminal surface
  protocol under ADR-01, so an upgrade breaks only that module, and a test catches a blank capture.
- **A program reads the user's screen content** — likelihood: medium, impact: high.
  Mitigation: a capture needs its own grant under ADR-14 P7 and P8, and review text that says it reads what a pane shows.
  "Which panes a program may capture" settles the targets.
- **A program reads a sibling terminal tab** — likelihood: medium, impact: high.
  Mitigation: the terminal records each tab's owner, and a capture follows the tab-scope rule. See "A program's tab
  scope in a terminal pane".
- **An older uniterm stops remembering trust after the user approves capture** — likelihood: low, impact: medium.
  Accepted: an older app loads no policies from a file that holds a kind it lacks, and keeps the file read-only until the
  user upgrades. This is UTERM-004's designed behavior for every new kind. See "Version skew".
- **A native controller stops connecting after the capture calls ship** — likelihood: medium, impact: medium.
  Accepted until UTERM-056 lands: until then, every ScriptWire change refuses native controllers built against another
  version. Amended 2026-11-23; see Decision Log. See "Version skew".
- **The capture error's reason kinds become published names** — likelihood: high, impact: low.
  Mitigation: programs switch on them, so they are append-only, and a test pins every existing name. A renamed reason
  is a new name beside the old one.
- **A huge page or pane exhausts memory** — likelihood: low, impact: high.
  Mitigation: the pixel area is clamped before rendering, as UTERM-019 settles, and results are capped per result and per
  run.
- **The capture power becomes a published name** — likelihood: high, impact: low.
  Mitigation: the power is versioned in the descriptor format, as UTERM-004 does for every power. See "Version skew".
- **Copy Screenshot replaces what the clipboard held** — likelihood: medium, impact: low.
  Accepted: Copy Screenshot is an explicit user command, as every Copy is. Programs never copy a capture.
- **The browser and program milestones rest on UTERM-019, which has built nothing** — likelihood: high, impact: medium.
  Mitigation: the full-page route, the clamp, handles, and the byte type are all UTERM-019's. M2 builds the full-page
  route and its clamp if UTERM-019 M4 has not, and UTERM-019 reuses them. M5 waits for UTERM-019 M3 and its byte type.
- **The program decisions rest on ADR-15, which is proposed** — likelihood: medium, impact: medium.
  Mitigation: a capture's authority stays under ADR-14, which is accepted. Only the rule that a program's capture behaves
  as the user's rests on ADR-15. If ADR-15 changes, that decision is revisited before M5.
- **A stale frame reports success** — likelihood: medium, impact: medium.
  Mitigation: an occluded or minimized web view or terminal can hold its last frame. Each applet's milestone checks a
  capture of a hidden or minimized pane, and "What an unselected tab or a hidden pane captures" settles the behavior.

## Milestones

### M1: Capture contract, copy, and save

**Status:** NOT STARTED

- An applet without the capability offers no screenshot command in the menu or the palette
- Copy Screenshot puts a PNG on the pasteboard, and a test checks it through an injected private pasteboard, never the
  general one
- Save Screenshot As… writes a PNG atomically, off the main thread, and a failed write alerts and keeps the earlier file
- Replacing an existing file keeps its permissions, and two saves to one path at once each report their own result,
  including when neither found a file there
- A completion that arrives after the time bound or a cancel is dropped, and never reaches the pasteboard, a file, or a
  later capture's result
- A capture of a hidden or minimized pane returns a current frame or a structured error, never a stale frame as success.
  The test changes the content after a first capture, then hides the pane, so a stale frame would fail it
- A pane capture leaves out the host's gutter, focus border, badges, and exec strip
- A pending capture shows its state, refuses a second capture of the same pane, and never moves focus
- The pending state never appears in the captured image
- A capture past its time bound fails with a non-modal status notice, and the user can cancel a pending capture
- When two copies overlap, the clipboard holds the image of the Copy the user ran last
- The image viewer, text viewer's plain text and PDF, data viewer, and questions applet capture, and each image matches
  what is on screen
- Each applet's check names its capture route, and the image viewer's names how its layer tiles render
- Each applet's check states what its tab content is
- Every capable applet offers the four screenshot commands with their fixed titles, whatever its tab count or chrome.
  The check names each command's menu, and each title matches what App Shortcuts binds
- A saved PNG at 2x records 144 dpi and pastes at its on-screen size
- The default file name is made safe from a title with `/`, `:`, control characters, a leading dot, an over-long title,
  and an empty title
- The save panel opens in the system screenshot folder, and falls back to Desktop when that value is unset, a `~` path,
  or a missing folder
- A capture of a target state the applet's check did not prove returns a structured error that names the reason
- Save captures the image when the command runs, and time spent in the save panel never counts toward the time bound
- Putting a large PNG on the pasteboard stays within ADR-08's main-thread budget
- The user takes a screenshot of each of those applets in the real app and confirms the images

### M2: Browser

**Status:** NOT STARTED

- A tab and a pane screenshot capture the viewport through `takeSnapshot`, and the pane's tab bar and toolbar appear in
  the pane capture only
- The full-page command captures the whole document through UTERM-019's route, and a page past the clamp gets a clamped
  image or a structured error. The check names whether the clamp crops, scales, or refuses
- A user capture and a program capture of one browser pane at the same time each return their own image
- A clamped image tells the user it was cut or scaled, and never reports a plain success. The check runs at 2x, where a
  page reaches the clamp at half the length
- A capture while the error page or a page dialog shows gives the image the screen shows
- A WebKit snapshot that never completes ends at the time bound, and a later capture of the pane works
- A capture of a hidden or minimized browser pane returns a current frame or a structured error
- The text viewer's Markdown, which renders in a web view, captures through the same route
- The user takes a viewport and a full-page screenshot of a long page in the real app and confirms both

### M3: Map viewer

**Status:** NOT STARTED

- The view-capture check on the map view is recorded, and the route it picks shows the tiles and pins as the screen
  does
- The pins in a capture come from the live marker views, and an offline snapshot with no tiles returns a structured
  error
- The pin list appears in the pane capture
- A capture of a hidden or minimized map pane returns a current frame or a structured error

### M4: Terminal and REPL

**Status:** NOT STARTED

- The capture patch builds on the pinned libghostty and draws the surface's current frame. If it cannot, the result is
  recorded in the Decision Log and the route goes back to the user before any other route is built
- The capture call returns before the frame completes, and the frame arrives through the render-thread callback
- A capture taken while the terminal redraws shows no tearing
- A capture of a hidden or minimized terminal returns a current frame or a structured error
- A terminal capture matches what is on screen, including colors and a terminal-drawn image, and a test catches a blank
  capture
- No libghostty type appears outside the terminal surface module
- The REPL captures through the same route
- The terminal records each tab's owner, and a script's capture of a sibling user tab is refused
- A script's capture of its source tab works after the user switches tabs, and a root whose tab closed or whose session
  was replaced maps to no tab
- A controller captures the first tab of a terminal pane its layout opened
- A pane of any owning applet that a program opens with open-pane starts with its first tab owned by that program,
  through the shared open-pane path, which closes `20261122-script-open-pane-leaves-first-tab-unowned`
- A tab a program opens in a terminal through the generic tab open is owned by that program, since the host carries
  the program's caller into the terminal's owner record
- The source tab comes from the tab the terminal's session start reports, kept beside the session root
- A change of the terminal pane's control ends the tab ownership it recorded, and a later capture of those tabs is
  refused
- A user capture and a program capture of one terminal at the same time each return their own frame

### M5: Scripts and controllers

**Status:** NOT STARTED

Waits for UTERM-019 M3, which builds handles and read-result, and for the byte type that UTERM-019's "Result encoding"
adds.

- A user's cancel, a time-out, or a revocation of a program's pending capture fails its pending reply or frees its
  handle with a structured error, under ADR-11
- A capture without the capture grant returns a structured error that names the power
- A capture whose image would show a tab outside the program's tab scope, including a title in the tab bar, is refused.
  A script's capture of its own source tab works
- A script without read access to the user's photo in its image viewer pane gets a named refusal, not the image. The
  same holds for a user-opened file in the text viewer and the data viewer
- A script without read access to the map's file captures the map without the file's pins and without their pin list
  rows, and its own pins show
- A capture and the viewer's replies agree on what the caller may see, through the same read scope
- A capture's ScriptWire reply holds until the PNG is ready and returns a handle, and its PNG reads back in chunks
- A pending capture that fails the authority re-check at completion frees its slot
- A program's pending capture never refuses the user's own capture of that pane
- Retained results are capped per result and per run, and a result over its cap is refused
- The structured error's reason kinds are append-only, and a test pins every existing name
- A program's capture of a pane outside its allowed targets is refused
- Pane close and run end free a completed capture result that was never read, under ADR-11
- A program's reply says when its image was clamped
- The descriptor format gains the capture kind, and its review text names what a capture of the source pane reveals
- A script's capture of its own questions tab works or returns a named refusal
- A refusal before the capture starts shows nothing to the user
- A program's running capture shows the pending state and can be cancelled
- A controller retrying a failing capture posts at most one notice per pane per run, names itself in it, and each reply
  carries the error

### M6: Amend UTERM-019

**Status:** NOT STARTED

Lands before UTERM-019 M1 ships, and does not wait for M1 to M5 here.

- UTERM-019's text names one pane capture power for every applet, and browser capture no longer appears as its own kind
- `:browser/snapshot` is gone from UTERM-019's capability set, and its snapshot checks point at this proposal's host
  capture
- UTERM-019's rule that next-events is the only command that waits names the capture's held reply as a second one
- If UTERM-019 M1 shipped first, browser capture is widened to every applet under version 2, and an approval under
  version 1 covers only the browser
- The amendment says that UTERM-019's PDF, find, and cookie results keep their own browser read-result, and that exec
  drivers' browser snapshot moves to UTERM-055
- If UTERM-019 M4 shipped `:browser/snapshot` first, the removal follows UTERM-019's rule that a dropped feature leaves
  the capability set

## Decision Log

- 2026-11-22: Drafted from the "Screenshot of a pane or tab" idea. The user chose copy and save as separate commands, a
  viewport capture plus a full-page variant for the browser, and capture by scripts and controllers for every applet.
- 2026-11-22: (addition) The user added program capture for every applet to the scope.
- 2026-11-22: (addition) The user chose Save Screenshot As… beside Copy. The idea named only taking a screenshot, so
  file writing, the save panel, and the default name and folder come with it.
- 2026-11-22: Revised after the draft's design critique. "Scripts and controllers capture too" said the PNG bytes read
  back "under UTERM-019's read-result shape". That shape is scoped to browser tabs, so the command, handle, and event
  stream became the open question "Where a program's capture command lives". The grant now names a bound under ADR-14
  P15. "Version skew" was added. The save route was corrected: it said Save writes through `AtomicFile` as the map
  viewer does, but the map viewer uses its own temp-and-swap write. The thread rule was corrected: it said WebKit's
  completion handlers run off the main thread, but WebKit and view rendering run on it. A time bound and cancel were
  added to pending captures. The open questions gained options for an upstreamed terminal patch, tab commands that
  follow the tab bar, a capture of the selected tab, owner-level tab scope, and an amendment to UTERM-019 before its M4
  ships. "Or a setting" was dropped from output scale. Risks were added for UTERM-019's unbuilt parts, ADR-15's status,
  and stale frames.
- 2026-11-22: Revised after the re-check. "Version skew" said a new driver on an old app gets an unknown-command error.
  That holds only on the existing `command` or `paneCommand` frame, since an unknown frame type ends the driver, so the
  bullet now says so. It gained the policy file direction. The host-level capture candidate now names its event
  carrier, and a pending-reply candidate was added. The browser capture amendment's gate moved from UTERM-019 M4 to M1,
  which creates the kind.
- 2026-11-22: Revised after the third critique pass. "Scripts and controllers capture too" said "the command replies at
  once with a handle, and a completion event names the handle". That reply shape was this draft's own mechanism, not
  the user's choice. It contradicted the pending-reply candidate, so the shape moved to "Where a program's capture
  command lives". "Version skew" now names the `refused` answer an older app gives for an applet that takes no
  commands. These fixes were not re-checked, since the proposal loop allows three passes.
- 2026-11-22: Review start: 5 milestones, 8 settled decisions, 9 risks, no `**Live after:**` lines or row gates, at
  commit "Leave UTERM-054's program reply shape open and name the old-app refusal". No out-of-scope statements. The user
  asked for an autonomous review of all 10 open questions.
- 2026-11-22: (autonomous) The terminal captures through a local libghostty patch that updates cells under the state
  mutex, draws under the draw mutex, and completes through a render-thread callback. Offering it upstream waits on the
  user. Converged in 1 pass.
- 2026-11-22: (autonomous) One pane capture power covers every applet. UTERM-019 is amended before its M1 ships, with a
  version 2 widening of browser capture as the fallback if M1 ships first. Converged in 1 pass.
- 2026-11-22: (autonomous) A program may capture only what its tab scope covers: the tabs it opened plus its source
  tab, checked against every tab the image shows. Converged in 1 pass.
- 2026-11-22: (autonomous) Capture is a host-level operation. Scripts reach it through new ScriptWire calls with a held
  reply. Program copy takes a capture handle through an image clipboard write. Exec drivers wait for UTERM-028's offer.
  Converged in 1 pass.
- 2026-11-22: (autonomous) Amended "Capture never blocks the main thread": a program's pending capture never refuses
  the user's capture, under ADR-14 P15. It said only that a second capture of the same pane is refused. Amended
  "Scripts and controllers capture too" to the held-reply shape. It said the shape was a handle with a completion
  event or a pending reply. Amended "Version skew": exec capture is offered through UTERM-028. It said capture rides
  the `command` or `paneCommand` frame.
- 2026-11-22: (autonomous) Every capable applet offers Copy Screenshot, Save Screenshot As…, Copy Pane Screenshot, and
  Save Pane Screenshot As…, with fixed titles. The browser adds the full-page pair. Converged in 1 pass.
- 2026-11-22: (autonomous) An applet captures only the target states its milestone proved, and refuses the rest with an
  append-only reason. Converged in 1 pass.
- 2026-11-22: (autonomous) A program saves a capture by reading its bytes and writing them itself. No program save panel
  is added. Converged in 1 pass.
- 2026-11-22: (autonomous) The map viewer checks view capture first and falls back to `MKMapSnapshotter`, with pins
  from the live marker views. Converged in 1 pass.
- 2026-11-22: (autonomous) Screenshots use the window's backing scale with recorded density, a safe title plus
  timestamp name, and the system screenshot folder with a Desktop fallback. Converged in 1 pass.
- 2026-11-22: (autonomous) The screenshot commands get no default key. Converged in 1 pass.
- 2026-11-22: (autonomous) Coherence review. The terminal records each tab's owner and adopts `CallerOwning`, so a
  program's capture follows the tab scope. Amended "Which panes a program may capture": it said every applet without
  per-tab owners counts a target pane as wholly the program's. Converged in 1 pass.
- 2026-11-22: (autonomous) Exec capture is a new exec protocol version with capture, read-result, discard, and an image
  clipboard write. Amended "Version skew": it said exec capture was a frame type offered through UTERM-028, which
  offers versions, not frame types. Converged in 1 pass.
- 2026-11-22: (autonomous) A program's refusal goes in its reply only. A running program capture shows the pending
  state and cancel, and a run posts at most one failure notice per pane. Amended "Capture never blocks the main
  thread": it said a failed capture shows an alert. It now posts a non-modal status notice, so it never takes focus.
  Converged in 1 pass.
- 2026-11-22: (autonomous) Coherence review. `:browser/snapshot` leaves UTERM-019's capability set, so one viewport
  capture has one program shape. M6 owns the UTERM-019 amendment and its version 2 fallback. The terminal risk now
  names the patch instead of a spike.
- 2026-11-22: (addition) The full-page variant was the user's choice, but the idea named only a pane or tab capture.
  This entry tags it.
- 2026-11-22: Growth question: the coherence pass added terminal tab owners, an exec capture version, an image
  clipboard write, a refusal and failure split, a notice bound per run, and the UTERM-019 amendment, all serving
  program capture. The user kept the owners, the split, the bound, and the amendment as correct and justified. The user
  dropped exec capture, since no proposal plans an exec-capable applet, and program copy to the clipboard, since the
  ask was program capture. Both went to the ideas file. Removed the settled "The exec wire for capture". Amended
  "Scripts and controllers capture too", "Where a program's capture command lives", and "Version skew", which said a
  program copies a capture by handle and exec drivers capture through a new protocol version.
- 2026-11-22: Re-check of the coherence fixes. Amended "Version skew" and "Where a program's capture command lives":
  they said ScriptWire ships in the bundle, so the capture calls carry no skew. Native controller entries speak
  ScriptWire from outside the bundle and are refused at hello by any ScriptWire change. The proposal now states this
  and accepts it, and the conflict with ADR-13 is filed as a bug. (autonomous)
- 2026-11-22: Review gate: the user kept the system screenshot folder. On exec drivers' browser snapshot, which the
  UTERM-019 amendment would have dropped, the user chose to bring exec capture back as its own proposal, UTERM-055.
  M6 now moves the exec snapshot to UTERM-055 instead of dropping it.
- 2026-11-22: The user accepted the proposal. No decision earns an ADR: program reach and authority are ADR-14's and
  ADR-15's, and the rest is scoped to this feature.
- 2026-11-22: Correction of fact for the growth question entry. It gave "since no proposal plans an exec-capable
  applet" as the reason for dropping exec capture. The map viewer and image viewer accept exec drivers today. The
  outcome stands, since exec capture returned as UTERM-055.
- 2026-11-22: Scheduled as UTERM-054 M6, UTERM-054 M1-M4, and UTERM-054 M5 in queue.md.
- 2026-11-23: Reopened design for one question, "What a program's capture shows of a file the program may not read",
  from bug triage of `20261122-capture-bypasses-image-viewer-read-scope`. The tab-scope rule checks no file read scope,
  so a program's capture of its source pane can show a user-opened file that the image viewer's and the map viewer's
  contracts withhold. The status stays `accepted`. M5 waits for the answer. M1 through M4 are user capture only and do
  not.
- 2026-11-23: From UTERM-056's acceptance. "Version skew" and the native-controller risk accepted the refusal for this
  proposal, with "the fix is a ScriptWire design call filed as a bug". They now accept it until UTERM-056 lands.
- 2026-11-26: From UTERM-062, which gives the viewers tabs and per-tab owners. The tab scope rule counted a pane of an
  applet with one tab as wholly the program's. Now a driver's own pane counts as wholly its own, and a viewer group
  pane's tab scope is the tabs the program owns. The open question on a file the program may not read gained the
  sub-question of tab titles in a pane capture.
- 2026-11-26: Settled "What a program's capture shows of a file the program may not read": a capture never shows a file
  the caller may not read. Part of an image from such a file is left out, as the map's file layer is, and a capture
  whose content is such a file is refused with a named reason. Unreadable tab titles show blank once UTERM-062 lands.
  The user chose this. M5 no longer waits on the question, and gained checks for it.

## References

- ADR-01: libghostty stays behind the terminal surface protocol
- ADR-04: uniterm owns key bindings
- ADR-05: each applet decides how it responds
- ADR-07: failure isolation
- ADR-08: UI responsiveness
- ADR-11: deferred applet replies never hide effects
- ADR-13: outside wires stay compatible across versions
- ADR-14: a controller controls what it opened
- ADR-15: a program's operation is the user's
- `spec/ideas.md`, "Screenshot of a pane or tab"
