# Ideas

Future improvements worth keeping that are not proposals yet, plus unsettled
refinements to revisit through use. An idea leaves this file when a numbered
proposal covers it.

## OAuth2 support: access and refresh tokens

uniterm obtains, stores, and refreshes OAuth2 tokens. This is the most important
idea here, and none of it exists today. It needs the authorization-code flow with
PKCE, a way to receive the redirect, token storage in Keychain, refresh before and
after expiry, revocation or sign-out, and a place to configure providers. Still
open: what uses the tokens, such as the browser, Janet scripts, or terminal tools.

SSO belongs with this. Sites' own sign-in pages are a separate, smaller concern:
they run as ordinary pages and pop-ups in the browser, and none has been tried
against a real provider. Risks there, none tested in uniterm yet: providers that
reject embedded browsers, as Google does based partly on the user agent; WebKit's
block on third-party cookies, which can break SSO flows that use a hidden iframe;
and passkeys, which need Apple entitlements.

## Browser: microphone and camera support

The browser rejects every microphone and camera request, so video calls and
voice features do not work. Real support needs usage strings in the app, a
per-site question, and a recording indicator. The strings make WebKit expose the
native API and ask macOS before the browser's permission delegate, and the
stand-in `navigator.mediaDevices` script has to go. What a page sees after someone
answers the macOS prompt has not been measured.

## Browser: manage profiles

Add, list, and remove profiles, and switch between them. Every browser pane
shares one default profile today. The profile button's popover is the expected
home for these controls. A second profile needs its own website data store, and
its ID would flow through the pane's description.

## Browser: custom search engines

Let the user add a search engine of their own. The search engine setting offers
a fixed list today.

## Browser: history in the address bar

Suggest pages from the user's history while typing in the address bar. The
browser keeps no history across tabs today, only each tab's own back and
forward list.

## Browser: file upload pickers

Let a page's `<input type=file>` open a file picker. An upload input does
nothing today, so sites that take a file upload do not work.

## Browser: HTTP login dialogs

Ask for a username and password when a server requests HTTP authentication. The
browser answers no such request today, so a page behind a basic-auth login shows
the server's own 401.

## Browser: custom URL scheme

Let a scheme such as `corp://` serve pages through a `WKURLSchemeHandler`. This
is the least settled idea here, and no use for it is decided yet. A Janet script
is the most likely thing to serve it, which would make it wait on Janet
scripting. Still open: who defines a scheme, and what a scheme page can reach,
including whether ordinary web pages can link to it.

## Terminal: call out a bell

When a terminal rings its bell, call out its pane and its tab. A highlight is one
option, and the form is still open.

## Scripting: type text into a terminal pane or tab

Let a Janet script send literal text to a named terminal pane or tab as input to
the running program. This is separate from sending keystrokes: text supplies
characters, while a key can represent an action such as Enter or an arrow.
Still open: whether text uses paste semantics, including bracketed paste.

This would change UTERM-003's explicit decision that no host function writes to
terminal input. That change is welcome; the existing decision is not a reason
to rule the idea out. UTERM-004 preserves the restriction today, so a proposal
would revisit it there too and settle the required control and trust grants.

## Scripting: send keystrokes to a terminal pane or tab

Let a Janet script send keys and modifier combinations to a named terminal pane
or tab, including Enter, arrows, Escape, and Ctrl-C. This complements literal
text input for interacting with shells and terminal programs. Still open: how
keys are represented and translated for the terminal's current input mode.

This also changes UTERM-003's explicit decision against terminal input
injection, which is fine. A proposal would revisit UTERM-004's matching
restriction and settle authorization alongside text input.

## Scripting: read a terminal pane or tab's screen

Let a Janet script read the current terminal screen of a named pane or tab,
including a full-screen program's display. This means terminal contents rather
than a screenshot. Still open: plain text versus cells with attributes and
cursor position, and how the active screen differs from a viewport scrolled
back into history.

This extends UTERM-003's host API with terminal content access it does not
provide today. A proposal would settle the control and trust grants for reading.

## Scripting: read a terminal pane or tab's scrollback

Let a Janet script read retained scrollback from a named terminal pane or tab,
including output no longer on the current screen. This is separate from reading
the screen: history can be much larger and full-screen programs may use an
alternate screen without adding their display to scrollback. Still open: ranges,
size limits, and how callers handle history changing or being cleared.

This also extends UTERM-003's host API. A proposal would settle authorization
and the distinction between access to the current screen and retained history.

A restored shell tab already shows its saved scrollback as plain text above the
first prompt. That text is a natural first thing to read, since it is already
plain text. Still open: whether it reads the same as live scrollback, or as its
own region the caller can tell apart.

## Scripting: ask a pane or tab what it shows

Let a program ask a pane or tab for its applet's state. Examples are the file a
map, text, image, or data viewer has open, the data viewer's sheet, and the
browser's address. Today `list-panes` gives each pane's applet, title, current
directory, and tabs. A viewer's directory is its file's folder, and its title
usually names the file, but no call returns the path itself. The browser's
`read` returns a tab's address for tabs its controller opened. The image
viewer's `wait` reply and `shown` event carry the image's path. The map, text,
and data viewers return no path, and the data viewer takes no program commands
at all. Exec drivers have no query message of any kind.

This would be a general query that each applet answers with its own fields,
rather than one-off commands. Reading a terminal's screen or scrollback, above,
could be the terminal's answer. UTERM-064 adds a `find-tabs` query, but it
returns identities only. UTERM-048 shows full pane state to the user, not to
programs. Still open: whether one call serves every applet or each applet
publishes its own, which fields each applet exposes, how the read scope hides
fields for files outside it, and whether exec drivers get the same query.

## Scripting: write images and other types to the clipboard

Let a script or controller write more than plain text to the clipboard. The first
example is an image, such as a pane screenshot that UTERM-054 captures for a
program. Today the clipboard-write power writes plain text only, on ScriptWire and
on the exec wire. Still open: which types beyond images, whether an image is passed
as bytes or by a capture's result handle, and whether each type needs its own
power or the clipboard-write power covers them all.

## Terminal: Kitty clipboard protocol

Support the Kitty clipboard protocol, OSC 5522, which libghostty handles from
Ghostty 1.4. uniterm denies its reads and writes today, and the program gets an
`EPERM` reply. A paste-event listing is the one part served now. When a program
turns on Kitty paste events, libghostty turns the user's own paste into a request
for the clipboard's type names, and uniterm answers it so the paste keeps working.

The protocol goes further than OSC 52 in several ways:

- A read or write can carry several MIME types, such as an image beside its text.
  uniterm reads and writes only plain text today.
- A request can name the primary selection. macOS has none, so uniterm reports it
  as unsupported.
- A program can name itself and ask to be remembered for the session. The
  permission prompt would show that name, and a remembered grant would skip later
  prompts.
- A write can be large. libghostty caps one write at 64 MiB by default.

UTERM-004's per-session clipboard policy and ADR-09's clipboard powers cover OSC
52 today. Support would need them to cover Kitty requests too.

## Screenshot of a pane or tab

Take a screenshot of the current browser tab, and of the current pane or tab of
any applet. Nothing here has been tried yet. The browser can use `takeSnapshot`,
though a full-length page needs more work. AppKit's view capture should cover
ordinary views, and will likely miss web, map, and Metal content. The terminal is
the open question: its Metal drawing needs a libghostty call, if one exists. A tab
that is not showing may have nothing current to capture.

Chosen so far. Each applet handles its own screenshots through an optional method
on the applet contract, since capturing the screen would need Screen Recording
permission. An applet with no method does not offer the command. AppKit capture is
a shared helper that an applet opts in to, never an automatic default, since it
would save a blank area for content it cannot see. A screenshot of a tab is just
the tab's content. A screenshot of a pane includes the pane's chrome, such as its
tab bar and toolbar, and leaves out the host's frame around the pane, such as the
focus border.

## Reorder tabs within a pane

Drag a tab to a new place in its own pane's tab bar. This covers one pane only.
Tabs cannot be reordered today. The gesture belongs in the shared `AppletTabBar`,
and each applet with tabs moves its own tab. The applet contract does not change.
Saving a layout already writes tabs in their current order. The selection is a
position, so a move has to keep the same tab selected.

Move Tab Left and Move Tab Right commands would give the palette a keyboard route.
They need no default shortcut. Tabs past the edge of a full bar are clipped, so a
drag cannot reach them.

## Move tabs between panes

Drag a live tab from one pane to another of the same type. The work starts with a
spike, then a proposal. The spike moves a live terminal surface and a live web
view between panes in one window, and watches for rendering, focus, and video
problems. Nothing has been tried yet, and only this could rule the idea out.

The proposal covers terminals first, since they hold far less state, then browsers
and any other applet with tabs. It changes the applet contract: a pane gives up a
tab and another adopts it. Rebuilding a tab from its description is no substitute,
since that kills the shell and reloads the page.

Still open for the proposal:

- Browser downloads, pending dialogs, and the script-opened tab limit belong to the
  pane. Opener links can end up pointing at a tab in another pane.
- Dragging a pane's last tab away should close the pane with no question and no
  undo entry. That path does not exist today.
- What undo means after a move.
- Moving between windows, since close stamps are per window.
- Control and trust in UTERM-004 depends on which pane a process runs in, so a move
  has to deal with existing grants.
- Browser profiles from the idea above fix a web view's data store at creation, so
  a live move between profiles has to be refused.

## Scriptable sidebar

A sidebar that scripts can program. It is a UI component, the way the palette and
the status bar are, and not a pane. Each window has at most one, and the user can
set it to the left or the right. This is not well fleshed out yet. It would come
after uniterm has proper scripting support.

The sidebars in the map viewer and the text viewer plans are a different thing:
each belongs to one applet and lives inside its pane.

## Automations scriptable from Bash

Let Bash scripts invoke automation operations and consume their results without
writing a Janet adapter. Launching an existing Janet file with arguments is
already possible, but does not provide a uniform command interface. Explore
direct CLI operations and explicit callable operations exposed by running Janet
scripts, controllers, or exec drivers. These are possible interfaces, not a
settled design. Structured input, output, errors, and exit statuses should make
the interface useful in shell workflows.

A design must assess compatibility with UTERM-004's security model rather than
assume a shell command inherits the automation's authority. Identify which parts
can use existing grants, which need new mechanisms, and which would require
explicit changes to settled decisions. The refinements below capture the open
questions.

## Sample presentation controller

Ship a sample controller that presents a slide deck. It is a controller, not a
new applet. One pane shows the current slide. Another shows speaker notes.
Controls move to the next, previous, or a chosen slide. It gives a user a
starting point for writing controllers, and a way to give a talk from uniterm.

UTERM-004 names a presentation program in its motivation, and its as-built
example drives slide, notes, and chart panes. That example is test-only. The
script lives in `Packages/UnitermKit/Tests/WindowKitTests/PresentationTests.swift:28`.
Its panes are hosted fixtures that `App/AppDelegate.swift:267` registers only in
debug builds. The repo has no samples directory, and no `.janet` file outside
test fixtures. The text viewer is the only production applet that takes remote
commands. Its schema in
`Packages/UnitermKit/Sources/TextViewerApplet/TextViewerRemote.swift:138` offers
inline Markdown, reload, scroll to a PDF page or heading, and find.

A thin version works today. A Janet script requests a layout with two text
viewer panes. It sends each slide as inline Markdown, or sends a PDF and scrolls
by page. The script's own terminal pane can read keys as the controls. Several
gaps limit a richer version. The text viewer emits no events, since remote
callers receive none (`TextViewerApplet.swift:52`), so the controller cannot see
the user navigate. No command opens a file by path. Inline Markdown has a size
cap. Image, browser, and canvas slides need those applets to take remote
commands first. UTERM-024, a draft, would let the controller declare palette
commands and shortcuts such as Next Slide, and read them as events. Clickable
controls in a pane would wait on UTERM-022's Questions applet. Still open: where
shipped samples live and how a user finds them.

## Go client library for controllers

Let a Go program act as a controller and command uniterm directly, without
shelling out to the `uniterm` command. This would make Go a scripting language
for uniterm beside Janet. It extends "Automations scriptable from Bash". That
idea holds the caller identity, authority, and lifecycle questions. This one
adds a language-neutral client contract and a Go library that speaks it.

A program commands uniterm over a unix socket with the binary script wire. The
socket address is in
`Packages/UnitermKit/Sources/ScriptWire/ScriptAddress.swift:8`. The wire is at
version 12 (`ScriptWire/ScriptProtocol.swift:12`), and both sides refuse any
other version. Its only documentation is the Swift source. Any same-user process
can connect, but it is admitted as a generic peer. Only the bundle's own
`uniterm` command may start a controller run
(`ScriptHost/ControllerIdentity.swift:84`). A controller package may already
have a native entry (`ScriptWire/ScriptProtocol.swift:537`). The command execs
that entry from a verified snapshot, and the entry connects back as the
controller. The only native client today is a Swift test fixture. The exec
driver wire is a different thing. It is JSON lines on a child that the app
launches to drive one applet (`ExecDriver/ExecProtocol.swift:3`), so it cannot
command uniterm.

The framing is simple, so a Go encoder is small. The blockers are contracts,
not code. The script wire is internal and version-locked. A third-party client
needs a published spec, shared conformance fixtures, and a compatibility policy.
That is a proposal-level decision, and likely an ADR. A Go process that connects
on its own is a generic peer. It gets no verified identity, no remembered
trust, and no declared permissions, so it falls back to per-call prompts or an
explicit pane grant. The native-entry route gives a Go binary full controller
identity today, if it implements the wire. It is still started through
`uniterm run`, though the Go code never shells out after that. Still open:
whether the library lives in this repo or its own Go module, and which identity
route it supports.

## Share a pane or tab in a screen share

Share one pane or tab in a video call, such as a Google Meet screen share in
Chrome. Sharing a whole uniterm window works today. Sharing part of a window
does not, since Chrome's picker offers only screens, windows, and Chrome tabs.
Native Chrome support is preferred. A sidecar program or a Chrome extension is
acceptable.

Nothing in the code captures or streams a pane. "Screenshot of a pane or tab"
above covers still captures through an optional applet method. "Move tabs
between panes" plans a spike that moves a live terminal surface and web view to
another pane. Both bear on this idea, and neither covers it.

The most promising route is a pop-out window that holds only the shared pane.
Meet's own window picker then lists it, with no extension or new permission.
Chrome captures windows through ScreenCaptureKit. Per WWDC22 session 10155, a
single-window capture keeps working when the window is covered, but pauses when
it is minimized. Moving a live Metal surface or web view to a new window raises
the same unknowns as the move-tabs spike, so the two belong together. The
original window also needs something in the pane's place. A fallback route
streams pane frames to a local page in a Chrome tab, and the user shares that
tab. It needs a frame source, an encoder, and a local server, and adds latency.
Its stream of terminal contents falls under UTERM-004's trust model. Capturing
uniterm's own window and cropping to the pane needs Screen Recording permission.
Per-applet capture avoids that permission but may give stills, not video. A
virtual camera through a Camera Extension works, but shows up in Meet as a
camera rather than a presentation. It also needs a system extension, signing,
and user approval. Chrome's Region Capture and Element Capture crop only
captured tabs, so they cannot narrow a native window share.

## Refinements

Unsettled details to resolve as we gain user experience, try different use cases,
and iterate on future proposals. These are questions, not decisions or promises
of support. Record concrete examples and observations here as they arise. Move
a refinement into a proposal when it is ready for a decision, and link that
proposal from any related ideas that remain.

### Terminal scripting: permissions and target scope

The four terminal scripting ideas above need refinements to UTERM-004's control
and trust model. Its existing caller identity, explicit ownership, target access
mode, same-window scope, and revocation rules provide a starting point. Current
pane-control permission does not already authorize terminal input or content
access. Input support would explicitly revise UTERM-003's prohibition, which is
an acceptable change.

Questions to test against real workflows:

- Should typing text, sending keystrokes, reading the screen, and reading
  scrollback each require a separate declared power and approval?
- Should access to the caller's own terminal session differ from access to
  another session? How should this work for different tabs in the same pane?
- Are existing source-pane and owned-group scopes sufficient for useful
  automation? Which use cases need an explicit grant to an existing unrelated
  pane or tab, and how should the user select and revoke that grant?
- How should ordinary scripts, interactive REPL evaluations, and packaged
  controllers request these powers? Which approvals should last for an
  operation, a connection or run, a verified version, or a signing identity?
- What should pane chrome show when a program can read terminal contents or
  supply input? Is the current remote-control marker enough for users to
  understand the granted access?

### Terminal scripting: input and read behavior

The API behavior also needs experience from shell automation, interactive
programs, and full-screen applications:

- Should literal text use paste semantics, including bracketed paste? How does
  a caller deliberately submit a command or send a control key?
- How are keys and modifiers represented and translated for the terminal's
  current input mode?
- Does a screen read return plain text, cells and attributes, cursor position,
  or several representations? Does it read the active terminal screen or the
  user's currently scrolled viewport?
- How are scrollback ranges and size limits expressed? What happens when output
  arrives, history is trimmed, or the user clears history during a read?
- What ordering or snapshot guarantees let a script send input and then inspect
  the result? Which workflows need to wait for output or a screen change?

### Bash automation: caller identity and authority

The current model authenticates a live process and binds it to a source session.
A shell-facing interface introduces another caller when it invokes a running
automation. Design needs to establish whose authority each resulting operation
uses and prevent an approved controller from unintentionally lending its powers
to an unauthorized caller.

- How is a Bash caller authenticated and bound to its source pane or tab? How
  do calls from outside uniterm obtain an explicit source grant?
- Does an invocation use the caller's grants, the automation's grants, an
  intersection, or an explicit delegation? Which use cases require delegation,
  and how would its scope, lifetime, approval, and revocation work?
- What operations can an automation expose? How are arguments, target panes,
  and returned information constrained so a callable operation does not bypass
  pane ownership, disconnected mode, same-window scope, or separate powers?
- How do discovery and results avoid revealing unauthorized panes, terminal
  contents, or other private state? Permission to invoke an action may need to
  differ from permission to receive its output.
- How do remembered controller approvals apply to operations triggered by
  external callers? Trust in a verified controller must not silently become
  trust in arbitrary Bash code or mutable request contents.
- What happens to queued and in-flight requests when a caller disconnects, an
  automation restarts, a source session closes, or a grant is revoked?

Existing pane provenance and target checks may cover direct CLI operations.
Calling an already-running automation may need additional invocation or
delegation rules. Whether the current model is sufficient remains unsettled;
a proposal should name any gaps and proposed changes explicitly.

### Bash automation: interface and lifecycle

- Which workflows need direct pane commands, one-shot automation invocations,
  or calls into a long-running automation? Which need inline Janet or Janet
  source from stdin as a separate convenience?
- How does a caller identify a live automation and discover its supported,
  versioned operations without relying on focus or stale process identifiers?
- How are requests and replies encoded for pipelines? Settle stdout versus
  diagnostics, exit statuses, streaming, timeouts, and cancellation.
- Can callers retry safely after losing a reply? Which operations need request
  IDs or another way to avoid repeating an effect?
- How would external invocations coexist with an exec driver's app-owned
  stdin/stdout protocol? Attaching a driver alone does not provide an external
  command endpoint.

## Exec driver path-read power

An exec driver holds no path-reading power today, so a driver cannot ask a viewer to open a path, and a viewer tells it
nothing about the file it shows. UTERM-015's decision 8 gives a driver no opens. The image viewer's driver `show` and
stepping wait on this, as would any applet whose driver reads. A proposal would define how a driver declares a read
scope, how the user approves it beside the run's launch approval, and how a revoked or ended grant stops queued reads.
It would reuse UTERM-015's scope rules, which apply to a controller and have no driver form. Still open: whether the
scope belongs in the driver's declaration, so a layout saves it, or only to a run.

## Browser: save tab URLs to a file

Write the URLs of a browser pane's tabs to a file, so a set of open pages can be kept, shared, or reopened later. No
command copies or exports tab URLs today. The browser's commands in `BrowserCommands.swift` are open location, reload,
back, forward, new tab, tab selection, and reveal latest download. A saved layout already records each tab's committed
URL and title and the selected tab, per UTERM-005. That record lives inside the layout file, so it cannot be saved or
opened on its own.

No standard covers a set of tabs fully. `text/uri-list` from RFC 2483 is registered with IANA and suggests `.uris` or
`.uri`. It holds one URL per line with `#` comments, and has no titles or selected tab. The Netscape Bookmark File
Format is HTML that every browser imports. It carries titles and folders, but it is a bookmark format with a plain
`.html` extension. Firefox's session files and OneTab's export are tied to one product. A uniterm JSON format with its
own extension, as GeoJSON has `.geojson`, would give a lossless round trip that keeps titles and the selected tab.

Export would be a browser command with a save panel, as the map viewer's GeoJSON save does in `MapViewerApplet.swift`.
It could filter schemes as the layout code does. Opening a file back needs a declared file type and a UTERM-015 router
entry, so the browser claims it, and would reuse the new-tab path. Two concerns carry over. Tab URLs can hold tokens,
as UTERM-005's risks note for the layout file. A file with many URLs opens many tabs at once.

Chosen so far. The export defaults to a uniterm JSON format with its own extension. It also offers `text/uri-list` and
Netscape bookmark HTML. The save panel's own format control picks among the three: `showsContentTypes` with
`allowedContentTypes`, read back through `currentContentType`, both from macOS 15. Each format needs a declared
`UTType`, since the system has none for `text/uri-list`.

The JSON format carries both an extension and an in-file tag, as GeoJSON does. The extension and its `UTType` are
what macOS uses: Finder, the save panel's format control, and UTERM-015's router. The type conforms to `public.json`,
so editors and `jq` still read it. The file opens with a tag and a version, such as
`{"type": "uniterm.tabs", "version": 1, "tabs": [...]}`. The tag lets a renamed file, a piped script output, or a
pasted text still say what it is. When the extension and the tag disagree, the tag wins. An unknown version is a clear
error. The format holds tab sets only. A shared envelope for other uniterm data waits for a second payload, and the tag
leaves room for one. The extension is uniterm-specific, such as `.unitabs`, to avoid colliding with a generic name like
`.urljson`, and its identifier sits under `dev.uniterm`.

Still open: the extension's name, the JSON format's fields, and which of the three formats open back into tabs.

## Palette: show a command's shortcut

Show a command's keyboard shortcut on its palette row, so running it from the palette teaches the faster key. A row
draws an icon, the title, and a right-hand kind label, and nothing more (`PaletteRowView` in
`CommandPaletteView.swift`). Command rows are built from the command's ID and title only, in
`MainWindowController+Palette.swift`.

The row must show the key that is live now, not the declared default. A user's remap replaces the default, and a
reserved key drops it for an applet's command. `CommandMenu.keyEquivalent(of:)` already reads the live key from the
menu, and `KeyEquivalentText.spell` already renders it. The docked palette's placeholder uses both for its own hotkey.
The row view needs a trailing key label, and the title's constraint against the kind label has to make room for it.
Hints need to refresh when the menu's keys change.

Still open: an applet's command may hold its key only while that applet's pane has focus, so which key does its row
show? Controller commands from UTERM-024 and UTERM-027 bind keys outside the menu, so their live key needs another
source.

## Palette: show what a command acts on

Every command row's right-hand label reads "Command", whatever the command acts on. The user cannot tell whether a
command hits one pane, the window, or the whole app. The label comes from `PaletteEntry.Kind.label` in
`PaletteRanking.swift`. The model already knows the answer: each command has a `CommandScope` of app, window, or pane in
`Command.swift`, and an owner. The palette uses the scope only to decide availability. A pane command runs against the
pane that had focus before the palette opened, per UTERM-002, and the row gives no hint of that either.

UTERM-042 covers part of this. Its "Palette commands: wording and target" section gives its own controller and tab
entries a detail line that states their reach. This idea covers every other command row. The work would pass the scope
into the palette entry and show it, perhaps as the target pane's applet name for pane commands, as tab rows already
show. The wording should follow UTERM-042's convention. The scope enum has no tab level, so "Close Tab or Pane" may need
a more honest label than its scope gives. Still open: whether the scope replaces the "Command" word or goes in a second
field or detail line.

## Browser: suspend background tabs

A browser tab that has loaded and then lost selection keeps its web view, its content process, its scripts and timers,
and its memory for as long as the pane lives. Selecting another tab only takes the old web view out of the view
hierarchy (`show(page:)` in `BrowserView.swift`). The tab still holds it. Many tabs add up, and UTERM-039 leaves a
controller's tab count uncapped. Its Revisit line already names "unloading of background tabs" as a trigger.

The browser already does part of this. A restored tab nobody has looked at loads only when it is first selected, and
only while the pane is attached (`loadIfNeverLoaded` in `BrowserApplet.swift`). Detach pauses and suspends media in
every tab (`setMediaSuspended` in `BrowserTab.swift`), and reattach lifts it. This idea covers the rest: a tab that has
loaded and then gone to the background, in an attached pane. It needs a proposal of its own.

The idea has two readings. Freeze keeps the web view and throttles or suspends its activity. WebKit's public API reaches
only media this way, through `pauseAllMediaPlayback` and `setAllMediaPlaybackSuspended`. Occlusion control is private
API, and an off-window web view is throttled but not frozen. That WebKit behavior has not been measured here. Discard
drops the web view and its content process, and rebuilds the tab when it is selected again, as Chrome and Safari do.
Only discard frees the memory.

The code is close to discard already. `BrowserTab` builds its web view on first use (`webView` and `isMaterialized`).
It already drops and rebuilds the web view after a content process ends or hangs (`replaceWebView`). It rebuilds from
`interactionState`, which keeps the back and forward history, the URL, and often the scroll and form state. A discarded
tab still loses its in-page script state and its media position. UTERM-005's recovery rationale warns against reloading
tabs nobody is looking at, which fits a reload on selection.

UTERM-052 and UTERM-053 address main-thread cost that grows with the tab count. Discarding would lower that cost, but
neither proposes it.

Still open: freeze or discard, and what triggers it, such as deselection, an idle delay, or memory pressure. Also open:
which tabs are exempt, such as one playing media, one with a download in flight, one holding unsent form input, one
waiting on a dialog, or one a controller is driving. Hidden panes in a background uniterm tab or window need the same
answer.
