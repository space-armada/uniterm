# UTERM-019: Browser Automation for Controllers

**Status:** accepted
**Created:** 2026-11-11
**Updated:** 2026-11-23

## Dependencies

- UTERM-005 M8, for controller tabs, the browser command schema, and the browser navigation and browser read
  permissions
- UTERM-004 M6, through UTERM-005 M8, for the permission framework the new permissions join
- UTERM-003, for the `uniterm` Janet module and its API version
- UTERM-041 M1, for M3: the marker slot that holds the run-end marker, its kind, and the call that performs its action
- UTERM-042 M2, for M3: "Rebuild Tab" in the tab's right-click menu and the palette, so the run-end marker never ships
  without a way to rebuild its tab

## Impacts

- UTERM-005 — "Control": its line "No command evaluates script in a page" stays true for a controller without browser
  script, and stops being true for one with it. That line is superseded in part once this proposal is accepted.
  Browser read and browser navigation gain version 2 meanings, per "Widened browser read and browser navigation". M8
  ships their version 1 in descriptor format 2, per "Permission descriptor format".
- UTERM-004 — "Permission scopes and approval flow" and "Verified artifact and run binding": four new permission kinds
  join the descriptor's permission set. Descriptor format 2 adds a version to every permission, and each (kind,
  version) has one meaning, per "Permission descriptor format".
- UTERM-003 — "The API is one Janet module": a second built-in module, `uniterm/browser`, joins `uniterm`, per
  "Helper names". A byte-string value reaches Janet, and ScriptWire takes the next version after the one it is at when this
  lands, per "Result encoding". It is 12 after UTERM-007 M5.
- UTERM-001 — "Commands that wait" and "Result encoding": the applet contract has a pending reply that an applet
  completes later, built by UTERM-007 M5. This proposal adds a byte carrier beside `JSONValue`.
- UTERM-022 — "Commands that wait": the Questions applet's form calls are host calls, so its pending reply lives in
  the host. This proposal's lives in the applet contract. Both follow ADR-11, and neither builds the other's.
- UTERM-004 — "Exec wire format": the command hook it added can reply later, and exec drivers match such replies by
  request ID. Result chunks reach drivers as base64 strings, per "Result encoding".
- UTERM-055 — "The frames' fields" names the exec keys of a read-result chunk, `data` and `offset`, which "Result
  encoding" leaves unnamed. M3 checks them. "How the app bounds browser reads in flight": M3 builds the read hold
  UTERM-055 settles for captures, and UTERM-055 M1 routes capture reads through it.
- The follow-up inspector-bridge proposal reuses "Capabilities" and "Page events", and adds private-API capabilities
  to the same set. Its Risks entry ties capability names to `uniterm/api-version`. Under "Capability names and the
  unavailable error" they are append-only instead, and a failure after an effect is that proposal's to define.

## Summary

Controller scripts drive their own browser tabs beyond UTERM-005 M8's navigate and read. They run JavaScript, follow
page events, answer page dialogs, capture pages, read and write cookies, and send trusted input. Everything here uses
public WebKit API. A capabilities command tells a script what this build can do.

## Motivation

Chrome exposes the Chrome DevTools Protocol on a debugging port, and tools such as Puppeteer drive pages through it.
WebKit has no such port. The findings note, `spec/reports/20261111-wkwebview-automation-vs-cdp.md`, shows that most of
what that protocol is used for can be built on public WebKit API. UTERM-005 M8 gives a controller navigation and URLs.
That is not enough to log in, fill a form, wait for a page, or check what it shows.

The private-API surface, such as network observation and the debugger, depends on a spike and belongs to the follow-up
inspector-bridge proposal. This proposal holds the work that has no such unknown.

## Design Decisions (Settled)

### Scope of every command

Decision: every command in this proposal acts only on a tab the controller opened, as UTERM-005 "Control" defines it.

- Aimed at any other tab, a command returns the structured error M8 returns.
- A tab a page opens from a controller tab belongs to no controller, as in M8.
- The tab and pane references are the ones UTERM-003 defines. No command addresses a tab by its index, per ADR-02.

Rationale: M8 already protects the user's own tabs this way. The new powers are stronger than navigation, so the
boundary matters more, not less.

### Permissions

Decision: four new typed permissions, separate from M8's browser navigation and browser read and from each other.

- Browser script covers running JavaScript, injecting scripts, answering page dialogs, and the dialog opened and
  script finished events.
- Browser input covers synthesized mouse, key, and scroll events.
- Browser cookies covers reading and writing cookies, per "Cookies".
- Browser capture covers snapshots, PDF output, and find in page.
- Navigation and frame events fall under browser read version 2, since they carry URLs. User agent, zoom, and
  print-media emulation fall under browser navigation version 2. See "Widened browser read and browser navigation".
  Amended 2026-11-11; see Decision Log.
- Each permission's approval review states its meaning. Browser script says a script can read and change anything the
  page shows, signed in as the user. Browser cookies says it returns session cookies, including HttpOnly ones.
- An approval stored before these permissions existed cannot cover them, per ADR-09.

Rationale: ADR-09 makes each power its own permission, and says one granted power never silently grants another. A
single automation permission would hand input and cookies to any controller that only needed JavaScript.

### Capabilities

Decision: a capabilities command returns the set of capabilities this build supports, as a record keyed by
capability, per "Capability names and the unavailable error". Amended 2026-11-11; see Decision Log.

- Public-API capabilities always report as available.
- The answer comes from state uniterm computes once at startup. It never waits on WebKit or on a script, per ADR-08.
- A command whose capability is unavailable returns a structured error naming the capability. It never crashes the
  app or the helper.
- The follow-up inspector-bridge proposal adds private-API capabilities to the same set, from its startup probe.

Rationale: a script can check before it relies on something, and a failure that slips past the check still reaches the
caller as an error.

### Page events

Decision: each controller tab keeps a bounded buffer of page events. A script reads it with a cursor.

- The events are navigation started, committed, finished, and failed, plus server redirect, web content process
  terminated, dialog opened, and frame appeared, per "Frames".
- A next-events command takes a tab, a cursor, and a timeout. It replies when events past the cursor exist or the
  timeout passes. The reply carries the events, the new cursor, and how many events were dropped since the cursor.
- A full buffer drops its oldest events and counts them. It never grows past its bound, and never blocks the app.
- The buffer exists only while the tab belongs to the controller. Closing the tab or ending the run discards it.
- Remote callers still receive no pushed applet events. UTERM-004's "Exec wire format" line stands. This is a reply to
  a command.

Rationale: the cursor means nothing is lost between reads, and the dropped count makes overflow visible. It needs no
change to the wire. The inspector-bridge proposal's console and network streams can use the same shape. A push stream
would amend UTERM-004 and the wire protocol, and needs rules for slow handlers and reentrancy. One-shot waits miss
events between waits and stall on a dialog during load.

### Script helpers

Decision: uniterm ships Janet helpers that hide the cursor bookkeeping, built into the helper binary beside the C host
functions.

- They are plain functions, not macros, such as a wait-for that waits on one event type and an each-event that calls a
  handler per event.
- They are part of the `uniterm` module family, in a `uniterm/browser` module, and follow `uniterm/api-version`, per
  "Helper names".
- They are built in because the default sandbox denies loading modules.

Rationale: the raw next-events loop is correct but wordy. Shipping the helpers means every script gets the same
correct handling of cursors and dropped events.

### Page JavaScript

Decision: a run-script command uses WebKit's `callAsyncJavaScript`.

- Arguments pass as typed values, never by building source text.
- The command replies at once with a handle. The promise's value or its error is read under that handle, per
  "Commands that wait". Amended 2026-11-11; see Decision Log.
- It can target a frame of the tab, per "Frames".
- The reply is page-controlled data. uniterm validates its size and shape like any other script input.
- A script injection command adds a script at document start or end, in the main frame or all frames, for the tab's
  later loads.

Rationale: typed arguments rule out injection through string building. Awaiting promises matches how pages work.

### Dialogs in controller tabs

Decision: a script with browser script answers alert, confirm, and prompt dialogs in its tabs.

- A dialog opening appears as a page event. An answer-dialog command accepts, dismisses, or supplies prompt text.
- Waiting for the answer never blocks the main thread, per ADR-08. WebKit's completion handler is held, as
  `PageDialog` already holds it.
- A tab that is not selected holds back the user's view of its dialogs until it is selected. The script may still
  answer them, per "An unanswered dialog". Amended 2026-11-27; see Decision Log.

Rationale: a page that calls `confirm()` stops until it gets an answer. Without this, a script cannot get past it.

### Cookies

Decision: a script with browser cookies reads and writes cookies only for the origins currently loaded in its tabs.

- It uses `WKHTTPCookieStore`, so HttpOnly cookies are included.
- A cookie for any other origin is refused with a structured error.

Rationale: the browser has one persistent website data store, per UTERM-005 "Website data". Access to the whole store
would hand a controller session cookies for sites it never opened. A controller can already reach an origin's cookies
by navigating there, which browser navigation allows.

### Trusted input

Decision: synthesized input behaves as the user's input does. Amended 2026-11-21; see Decision Log.

- A synthesized click moves focus as the user's click does. Keys go to that tab.
- A key press sent to one of the controller's tabs that does not hold focus first focuses that tab, as the user's
  click would, and then goes to it. The user can type only into a focused tab, and a controller's keys follow the same
  path. Amended 2026-11-21; see Decision Log.
- uniterm builds AppKit events and delivers them to that tab's web view directly.
- Synthesized keys go only to the web view. They never reach window keys or the app menu, per ADR-04. A menu command
  acts on the focused pane, outside the controller's tabs. This is ADR-15's carve-out for authority: ADR-14 confines a
  controller to what it opened, and a window key would reach past that.
- Trusted input carries user activation. A page can then open pop-ups, write the clipboard, enter fullscreen, and play
  sound, as if the user had clicked. Browser input's review text says so. Amended 2026-11-11; see Decision Log.

Rationale: a program's input is the same operation as the user's, and it behaves the same way, per the retraction of
ADR-12 and UTERM-037. A click that moves focus is what the user's click does. Events from page JavaScript are
untrusted, and pages refuse them for pop-ups, clipboard writes, and many form controls. Events WebKit receives through
AppKit count as real input.

### What is never restored

Decision: injected scripts, the user agent, zoom, and print-media settings that a controller sets are never saved in
the layout. A relaunch or an undo never re-runs a controller's scripts, per ADR-03.

### Frames

Original question:

How a script names a frame for run-script and injection.

- A frame ID uniterm assigns and reports in page events.
- A selector path, such as an iframe's name or URL. It is readable, but not unique.
- Main frame only in this proposal, with frames added later.

Decision: a frame ID that uniterm assigns to each frame's document. Run-script checks at use that the frame still
holds that document. Main frame only is the fallback if WebKit cannot target a held frame. (autonomous)

- A document-start script in the controller world runs in every frame and reports in. uniterm keeps the
  `WKFrameInfo` that WebKit attaches to the message, never a value the page supplies.
- The same script makes a random token for its document and keeps it in the controller world, where page script
  cannot read or change it. The report carries the token, and uniterm records it with the ID. Controller code can
  post a report too, but WebKit attributes it to the frame it came from, so it can change only that frame's own token.
- An ID names one document in one frame. A new document in the same iframe gets a new ID. For a controller-world run,
  the old ID is stale.
- A frame-appeared event carries the ID, the frame's origin, and its parent's ID. A list-frames command returns the
  tab's live frames. Both need browser read version 2 or browser script, since a script cannot target a frame it
  cannot name.
- A controller-world run-script with a frame ID checks, inside the same call and before its body runs, that the frame
  still holds the token recorded for the ID. A same-origin navigation inside the frame fails the check.
- A page-world run-script with a frame ID checks, inside the same call, only that the frame still holds the recorded
  origin. An opaque origin never matches. Its arguments are visible to every page script of that origin anyway, so a
  same-origin replacement document learns nothing more.
- A failed check or a gone frame returns a structured error. A controller-world run never runs in another document,
  and no run falls back to the main frame. Amended 2026-11-11; see Decision Log.
- Injection does not take a frame ID. `WKUserScript` targets the main frame or all frames, as "Page JavaScript" says.
- M3's first check proves that a held `WKFrameInfo` still targets its frame, including a cross-origin frame. If it
  does not, run-script targets the main frame only, and frames reopen as a design question.

Rationale: the public `WKFrameInfo` header says the object does not identify a frame across delegate calls, so
uniterm must name frames itself. The ID is per document, and the check runs at use. Together they keep a
controller-world script's arguments, such as a password, from reaching a document that replaced the one the script
chose. A page-world run keeps them from reaching another origin. A selector
path is page-controlled and not unique. Main frame only leaves cross-origin iframe flows undone, such as embedded
logins and payment fields. Converged in 1 pass.

### Widened browser read and browser navigation

Original question:

"Permissions" puts page events and find in page under browser read, and user agent, zoom, and print-media emulation
under browser navigation. UTERM-005 defines browser read as URLs and titles, and browser navigation as open, navigate,
reload, back, forward, and select. ADR-09 says a change in permission meaning cannot increase an existing approval. An
approval stored under M8's meaning must not cover the new commands. Raised by the review's ADR check.

Decision: browser read and browser navigation get version 2 meanings. Each permission in the descriptor carries its
version, and an approval under version 1 covers only UTERM-005 M8's commands. Find in page moves to browser capture.
Dialog and script events go under browser script. (autonomous)

- Browser read version 2 covers URLs and titles, plus the navigation started, committed, finished, and failed, server
  redirect, content process terminated, and frame appeared events. Browser script also unlocks frame appeared and
  list-frames, per "Frames".
- Browser navigation version 2 adds user agent, zoom, and print-media emulation.
- Browser capture covers find in page, beside snapshots and PDF output.
- Browser script covers the dialog opened and script finished events, per "Commands that wait".
- Each (kind, version) pair has one meaning, per "Permission descriptor format". Amended 2026-11-11; see Decision
  Log.
- Each build's review text describes only what that build grants.

Rationale: ADR-09 says a change in meaning cannot increase an existing approval. UTERM-004 already compares a
permission's semantic version against the approval, and the version works in either build order. Find returns a match
result, so repeated queries recover any text on the page. That is page content, not an address, and capture already
reveals it. A dialog's message is page text too, so its event cannot ride under browser read. Amending UTERM-005 first
would bet on M8 starting after this proposal is accepted, when M1 starts after M8. New permission kinds for events and
settings would add review entries with no power behind them that the version-2 meanings lack. Converged in 2 passes.

### Commands that wait

Original question:

How a command replies when its answer comes later. Next-events waits up to a timeout, and run-script awaits a promise.
An applet's `perform` returns its reply synchronously today, and the dispatcher delivers commands one at a time on the
main thread. On the script side, a `uniterm` call blocks the Janet VM until its reply arrives. A page that calls
`confirm()` from a run-script stops the promise, and the same script cannot answer the dialog while it waits. Raised by
the review.

Decision: next-events is the only command that waits, through a deferred reply in the applet contract. Every command
whose WebKit call finishes later returns a handle at once, and its result is read under that handle. (autonomous)
Amended 2026-11-15; see Decision Log.

- The applet contract has a pending reply that the applet completes later. UTERM-007 M5 built it for the text viewer's
  wait command, and this proposal's M2 reuses it for next-events. A schema entry marks a command that may wait with
  `mayWait`, and dispatch fails a pending reply from any other command. Before a pending reply completes, the
  dispatcher checks the caller's authority again. Revocation, a control change on the pane, run end, and pane close
  fail it. The dispatcher caps pending replies at 64 per window.
- Run-script replies at once with a handle. The result goes into a slot for that handle, outside the event buffer, so
  no burst of events can push it out. A script finished event naming the handle enters the buffer. A read-result
  command returns the value or the page's error, in chunks per "Large results". Each tab caps its outstanding runs.
- Snapshot, PDF output, find in page, and cookie reads and writes follow the same pattern, per "Large results".
- A dialog that opens while a script runs is the next event the script sees. The script answers it, and the promise
  can then settle.
- Each event kind is gated by the permission whose power it reveals, per "Widened browser read and browser
  navigation". Next-events needs at least one permission that gates an event kind, and returns only the kinds the
  caller holds. Events the caller cannot see neither count as dropped nor end its wait.

Rationale: an applet's `perform` replies synchronously today, and a `uniterm` call blocks the Janet VM until its reply.
A run-script that waited on its promise would deadlock on a page `confirm()`, since the script could not answer the
dialog. An early error would say nothing ran when the script had already run, which breaks the contract that an error
leaves the applet unchanged. Deferring only a read means a failed pending reply never hides an effect. A result kept
outside the ring cannot be evicted, and a side-effecting script cannot be safely run again. Polling with a sleep
would not resume in the REPL, which does not run Janet's event loop. Converged in 2 passes.

### Capability names and the unavailable error

Original question:

The symbols the capabilities command returns, and the error kind for an unavailable capability.

- Reuse the existing `unsupported` kind, with the capability named in the message.
- Add a new `unavailable` kind, so a script can tell "this build cannot" from "this applet has no such command".

Decision: the capabilities command replies with a record keyed by capability. Names are append-only. An unavailable
capability returns a new applet code, `unsupported-capability`, carried on the existing wire kind `unsupported`.
(autonomous, judge)

- The reply is `{:available {:browser/run-script true ...}}`. Only record keys reach Janet as keywords, so a list of
  symbols would arrive as strings and fail every membership test.
- Names are namespaced by applet type and named for a feature, never for a permission. This proposal's names are
  `:browser/events`, `:browser/run-script`, `:browser/inject-script`, `:browser/frames`, `:browser/dialogs`,
  `:browser/snapshot`, `:browser/pdf`, `:browser/find`, `:browser/page-settings`, `:browser/cookie-store`,
  `:browser/pointer-input`, and `:browser/key-input`.
- A name never changes meaning. A dropped feature leaves the set. A rename adds one name and drops the other.
  None of this bumps the browser command schema's major version. Together with UTERM-020, the set stays within 64 names, the
  most fields a script record holds.
- `unsupported-capability` comes back only for a capability missing from the set, and only when nothing ran. A listed
  capability that cannot run now returns `failed`, which also means nothing ran. A failure after an effect is
  UTERM-020's to define.
- The message names the capability. Janet sees `:unsupported`, as it does for a wrong applet type or schema version.
  The script already knows which type and version it sent.
- Any caller that may command the pane may call the capabilities command. It needs no browser permission.
- Skew: the schema version is a major and a minor, per UTERM-007 M5. New commands and new reply keys bump the minor,
  never the major. A script on a build without this proposal gets `:bad-argument` from the capabilities command, and
  nothing runs. The shipped helpers read that as an empty set. An older script on this build keeps working, since its
  major is the same and its minor is no higher than the applet's. Amended 2026-11-15; see Decision Log.

Rationale: an unknown command already maps to `:bad-argument`, so the open question's premise, that a script cannot
tell "this build cannot" from "no such command", does not hold. A new wire kind would buy a distinction no current
caller needs, at the cost of a ScriptWire bump. A command schema version matches on its major, so a major bump for a
rename would break every browser script, including scripts that never check capabilities. UTERM-020 can fail a capability the
startup set lists, so the error kind follows membership in the set. Judge after 3 passes, on budget. The critic moved
from bare error reuse, to a symbol set with schema bumps, to this record. Each move rested on code facts the judge
re-checked.

### Permission descriptor format

Original question:

How the four permissions enter the controller descriptor. UTERM-004's format 1 knows only `pane-control` and
`capability`. Candidates: new kinds in a format 2, coordinated with how UTERM-004 M6 and UTERM-005 M8 add browser
navigation and browser read, or browser permissions as one kind with typed scopes.

Decision: descriptor format 2 adds a required `version` on every permission, `pane-control` and `capability`
included. Each build knows a fixed
set of (kind, version) pairs, each with one meaning, one review text, and the versions it covers. (autonomous)

- UTERM-004 M6 builds format 2, with its clipboard and host launch kinds at version 1. UTERM-005 M8 adds browser
  navigation and browser read at version 1. This proposal adds their version 2 and browser script, browser input,
  browser cookies, and browser capture at version 1, in the same format. Amended 2026-11-11; see Decision Log.
- An unknown kind or version refuses the whole descriptor at load, as an unknown kind does in format 1. The same kind
  listed twice is refused.
- Approvals record (kind, version, scopes), which UTERM-004 already compares. A request covered by an approved version
  needs no new review. A higher version needs one.
- Format 1 descriptors keep working with format 1's two kinds.
- Each command is gated on its own permission alone. A browser read at version 1 hides only the events version 2 adds.
- Skew: a build without M6 refuses format 2 at load. A build that lacks a kind or version refuses it at load. A newer
  app reads older formats and versions with their own meanings. An older app reading a newer policy file authorizes
  nothing, per UTERM-004. No deploy order is needed.
- Skew for exec drivers: a deferred reply reaches a driver matched by request ID, as layout replies already do. An old
  driver never sends the new commands. A new driver on an old app gets `unknown-command`, and nothing runs. The
  `unsupported-capability` code reaches a driver as a new code string. A driver that does not know it treats it as a
  refusal, and nothing ran.

Rationale: approvals must key on meaning, not on file layout. A new format per meaning change would make a signed
update that only bumps the format re-prompt for nothing, or else let a changed meaning slip past ADR-09. The fix for
that is a per-format table of meaning versions, which is this version field in a hidden form. UTERM-020 adds six more
kinds, and the field carries them with no further format bump. The rule changes the "Widened browser read and browser
navigation" line that the format carries the version. The version now rides in each permission, and each (kind,
version) has one meaning. Converged in 1 pass.

### Content world

Original question:

Where run-script and injected scripts run by default.

- An isolated world. The page cannot see or tamper with the controller's code, but the script cannot read page
  JavaScript state.
- The page's own world. The script sees everything the page's scripts see, and the page can interfere with it.
- The caller names the world on each call, with one of the two as the default.

Decision: run-script and injected scripts run in an isolated controller world by default. A call may choose the page
world instead. (autonomous)

- The choice has exactly two values, isolated or page. A script cannot name a world, so it can never reach uniterm's
  own worlds, such as the unsent-input tracker's. The frame reporter runs in the controller world, per "Frames".
- One isolated world serves every controller. A tab belongs to one controller for one live grant, so no two runs
  script the same document.

Rationale: in the page world, the page can wrap, detect, and fake the controller's code, so no result could be trusted
more than the page. Some tasks need page JavaScript state, such as a framework's store, so the page world stays
available on request. Denying the page world would not make a boundary, since the shared DOM lets a script insert a
`<script>` element. Converged in 1 pass.

### Buffer size and event contents

Original question:

How many events a tab's buffer keeps, and how much of a URL an event carries. A full URL may carry tokens, which is
why browser read covers events.

Decision: each tab's buffer is bounded by event count and by bytes, and every event fits one reply. The exact numbers
are set in M2. (autonomous)

- An encoded event always fits one script reply, which holds 63 KiB, with room to spare. A URL over its field cap is
  cut to a prefix and carries a truncated flag. A dialog message has its own cap and flag.
- A reply carries as many events as fit, and the rest wait for the next read. The cursor always moves forward.
- The buffer stores only the event kinds the run's permissions cover. Hidden kinds never take its bytes.
- A byte budget per run sits above the per-tab budgets.

Rationale: an event too large for one reply would stop the cursor for good, or would be dropped without a count.
Either breaks the settled promise that nothing is lost between reads. A count bound alone does not bound memory.
Stripping query strings hides nothing, since browser read returns full URLs, and it breaks waits on OAuth callbacks.
Converged in 1 pass.

### Large results

Original question:

How a result larger than one message reaches the script. ScriptWire caps every message body at 64 KiB, and an exec
frame at 1 MiB. A viewport snapshot or a PDF is usually larger. Raised by the review.

Decision: chunked reads under a handle. Every command whose WebKit call finishes later replies at once with a handle,
as run-script does. (autonomous)

- Snapshot, PDF output, find in page, cookie reads, and cookie writes each reply with a handle. WebKit reports each of
  them through a completion handler.
- A completion event names the handle and carries the result's byte size. Each command's permission gates its event.
  Next-events needs at least one permission that gates an event kind.
- A read-result command takes a handle and an offset, and returns a chunk. A chunk's encoding fits one reply.
- Retained bytes are capped per result and per run. A result over its cap is refused with a structured error.
- A slot is freed on discard, at run end, and on revocation. A completed read does not free it, so a script can retry a
  chunk.

Rationale: a 63 KiB reply cannot carry a snapshot or a PDF. Writing results to disk would need the unscoped `fs-read`
capability and would leave page images behind after a crash. UTERM-020 rules out such files. Writing to a path the
script names would let the app write where the helper's sandbox refuses. Raising the message cap still fails for a
large PDF, and encoding tens of MiB on the main thread works against ADR-08. Chunked reads work on any transport and
match UTERM-020's body chunks. Converged in 1 pass.

### An unanswered dialog

Original question:

What happens when a script does not answer a dialog.

- A timeout, then dismiss.
- A timeout, then show the dialog to the user in the pane.
- Show it to the user at once, and let the script answer first if it can.

Decision: a dialog in a controller tab shows to the user as it does today, and a script with browser script may answer
first. The first answer wins. A dialog in a controller tab takes focus as any tab's dialog does. (autonomous)
Amended 2026-11-27; see Decision Log.

- The dialog appears when its tab is selected, as today. When the script answers first, the
  user's view of it closes. When the user answers first, answer-dialog on it returns a structured error.
- A dialog in a controller tab takes the first responder exactly as any tab's dialog does. The in-pane dialog takes it
  when the pane held focus. A controller tab has no exception.
- A tab that is not selected holds back only the user's view. A script may answer a dialog there, so a controller's
  own `confirm()` never stalls its run. Amends "Dialogs in controller tabs".
- At run end or revocation, an unanswered dialog simply stays with the user.

Rationale: holding a dialog for the script would leave the user looking at a frozen page with no dialog and no
explanation. Dismissing after a timeout would cancel a confirm or a prompt that nobody chose to cancel. A hold until
run end freezes the page for a run that never handles dialogs. Showing the dialog at once needs no timer, and
revocation needs nothing new. Converged in 1 pass.

### Injection lifetime

Original question:

How long an injected script lasts: until removed, until the next top-level navigation, or for the run.

Decision: an injected script lasts until the script removes it, the run ends, or the grant is revoked, whichever comes
first. One owner per tab keeps the tab's user-script list. (autonomous)

- Injection returns an ID, and a remove command names it. Each tab caps its injections.
- One per-tab owner holds the user-script list. It rebuilds the list in a fixed order: uniterm's media-capture,
  unsent-input, and frame-reporting scripts first, then the controller's injections. Every removal goes through it,
  since WebKit offers only removal of every script at once.
- A web view rebuilt after a content process loss or a hang reinstalls the controller's injections while the run is
  live. After the run ends, a rebuild never reinstalls them. The content process terminated event tells the script a
  rebuild happened.
- Removal applies to loads that start after its reply.

Rationale: ADR-09 ends authority at run end and on revocation, so no injection outlives them. Multi-load flows, such
as redirect chains and sign-in callbacks, need an injection to span loads. A script must be able to take back an
injection it no longer wants without ending its run. Today the unsent-input tracker's removal wipes the media-capture
script too, since no one owns the list. A single owner fixes that, and the M3 checks that removal leaves other scripts
in place depend on it. Converged in 1 pass.

### What a run leaves in its tabs

Original question:

A run-script can add a listener or a timer to a controller tab's document, in either content world. When the run ends
or its grant is revoked, the tab passes to the user, and its remote-control marker goes away. The listener keeps running
until the document unloads. It could read what the user types and send it out with `fetch`. ADR-09 says revocation
prevents new authorized effects. Reloading the document ends the code, but loses unsent input, which UTERM-005 "Unsent
input" guards on close and hang recovery. Raised by the review.

Decision: at run end or revocation, uniterm rebuilds every tab whose documents the run scripted, per "Reach of the
run-end cleanup". Amended 2026-11-11; see Decision Log. The one exception is a document
holding unsent input, whether the user or the controller typed it. Such a tab keeps a marker until its scripted history
entry is gone. Amended 2026-11-21; see Decision Log. A post-result page is spared the same way, whoever caused the
post. Amended 2026-11-21; see Decision Log. (autonomous)

- A document counts as scripted when run-script touched it, or when it loaded while one of the run's injections was
  active. A tab that a scripted document opened during the run counts too.
- The run's injections are removed before any rebuild, so the fresh document runs none of them.
- Unsent input counts the same from either source. The unsent-input tracker sees a field a controller's trusted input
  filled as it sees the user's typing. A tab holding either is spared.
- uniterm does not tell the user's input from the controller's. A form the controller fills and submits leaves a
  result page that counts as if the user had done it, per ADR-15.
- A rebuild never resends a form and never asks. A post-result page is spared, whoever caused the post, per "Reach of
  the run-end cleanup".
- A tab that is not rebuilt shows a marker saying a controller's code may still run in it. The tab's right-click menu
  offers a rebuild under the marker's meaning, and so does the palette, per UTERM-042. A click on the marker itself
  does nothing. The rebuild goes through the existing unsent-input question. Amended 2026-11-21; see Decision Log. The marker follows the scripted history entry. A same-document
  navigation does not clear it, and going back to a cached scripted page shows it again.

Rationale: a listener a run-script adds keeps running after the tab passes to the user. It can read what the user
types and send it out, which breaks ADR-09's promise that revocation prevents new authorized effects. A reload ends
it. Rebuilding over unsent text would discard it, and the text is the same whoever typed it. The user's own
reload never reads unsent input. The
question in UTERM-005 "Unsent input" guards close, quit, and hang recovery, and a rebuild is a close of the old web
view. Sparing every tab with unsent input leaves the common automation path unrebuilt, since a controller's trusted
input fills forms too. The same holds for a post-result page the controller submitted. The user accepted that cost:
fewer tabs are rebuilt at run end, and they keep a marker instead. Closing tabs loses the page the automation produced. Disclosure alone leaves the code running
where a reload is safe. Converged in 1 pass. Amended 2026-11-21; see Decision Log.

### Full-page snapshot

Original question:

Whether a snapshot can cover the whole page. Candidates: `takeSnapshot` with a large rect, scroll-and-stitch, or PDF
only.

Decision: a full-page snapshot uses `takeSnapshot` with a rect covering the content size. M4's first check proves it.
If WebKit leaves the off-screen part blank, a full-page image comes from rasterizing `createPDF` output instead.
(autonomous)

- The content size is read in the isolated controller world.
- A page that scrolls an inner container gets its viewport, and lazy content off-screen shows as placeholders. The
  command's documentation says so.
- Pixel area is clamped before rendering, so a page cannot force a huge bitmap past the per-result byte cap.
- Scroll-and-stitch is not used. It changes the page under the capture permission and needs the input power.

Rationale: both routes produce a full-page image without moving the page. Scroll-and-stitch fires scroll events,
triggers lazy loading, and repeats sticky headers. Leaving full-page images to PDF would give image callers only the
viewport. Converged in 1 pass.

### Helper names

Original question:

Which helpers ship, and whether they live in `uniterm` or a separate built-in module such as `uniterm/browser`.

Decision: a built-in module, `uniterm/browser`, that follows `uniterm/api-version`. Its helpers read through an
explicit reader value the script holds. (autonomous)

- `(browser/events pane tab schema-version)` returns a reader. It records the buffer's head cursor when it is made, so
  a script makes it before it navigates or runs a script, and no event between the action and the first read is
  missed. The reader carries the caller's browser schema version, and every helper call sends it.
- `wait-for` takes a reader, an event kind, and a deadline. `each-event` takes a reader, a handler, and a stop rule.
  `await-result` takes a reader, a handle, and a deadline. It waits for the handle's completion event, reads every
  chunk, and returns the whole value. `capabilities` returns the available set, and reads `:bad-argument` as empty.
- Events a helper passes over stay queued in the reader. No helper consumes another's events.
- A dialog opened during any wait goes to an `:on-dialog` handler. With no handler, the helper raises a structured
  error carrying the dialog. A dialog is never skipped.
- Every wait has a deadline, and loops next-events under its maximum timeout.
- Dropped events are always reported the same way: the helper raises a structured error that carries the dropped
  count, unless the caller passed an `:on-drop` handler. `await-result` checks the result's slot after any drop, since
  the slot outlives the event.
- `await-result` discards its handle on every exit path.
- The helpers use no `ev/` calls, since the REPL does not run Janet's event loop.

Rationale: helpers that skip a dialog would stall on the exact `confirm()` that "Commands that wait" was settled to
handle. A start point taken when the helper is called misses a load that finishes before the first read. A start
point at the oldest event returns an earlier load's events. A hidden cursor shared per tab would let one helper eat
another's events, and would be hidden state the script cannot see. Pinning the build's schema version inside the
helpers would bypass the version check, so a changed event shape would reach an old script with no refusal. A
separate module keeps UTERM-020's console and network helpers, and later applets' helpers, out of `uniterm`. A second
version number would guard no skew, since the helpers and the C functions ship in one binary. Blocking wrappers for
each handle command would hide the handle, and an interrupted wrapper would leave a slot nobody can free. Converged
in 1 pass.

### Reach of the run-end cleanup

Original question:

"What a run leaves in its tabs" reloads scripted documents, but three cases escape it. A page that came from a form
post is exempt, even when the controller submitted the form. A scripted document the tab navigated away from can come
back from the back-forward cache with its listeners alive. A page-world run-script can register a service worker,
which survives a reload and runs on the user's later visits. Raised by the coherence review.

Decision: at run end or revocation, each scripted tab is rebuilt instead of reloaded. A post-result page is spared from
the rebuild, whoever caused the post. Amended 2026-11-21; see Decision Log. Service worker registrations that are new
since the run started, for scripted sites, are removed. (autonomous, addition)

The rebuild is uniterm's own work when a run's permission ends. ADR-15 says such work is not the program's operation,
so it follows its own rules rather than a user action's: it never resends a form and answers its questions no. It
still treats what the program left the way it treats what the user left, as ADR-15 asks. Unsent input and a
post-result page count the same from either source.

- A rebuild drops the web view and builds a fresh one that restores the tab's history and loads the current entry
  anew, as recovery from a content process loss already does. Every live and cached document the run scripted is
  gone, and no form is resent.
- A post-result page is spared from the rebuild, whoever caused the post. A form the controller filled and
  submitted counts as if the user had done it. A spared page keeps its marker until its scripted history entry is
  gone, as a tab spared for unsent input does. Nothing attributes input, so nothing can fail to.
- The user accepted the cost. More tabs keep a page the controller scripted, behind the marker, instead of being
  rebuilt. The page's code can run until the user chooses the tab's "Rebuild Tab" or the history entry goes.
- At run start uniterm records which scripted-site data records already hold a service worker registration. At run
  end it removes registrations from sites that had none. A record covers a whole site, so a registration added on
  one host of a site that already had one survives. A registration the user's own tab added during the run is
  removed too. Changes to other site storage stay, as an accepted risk.
- The rebuild waits only for an open dialog, since a dialog stops page JavaScript. While it waits, the tab shows the
  marker. Other open questions, such as a download, an external app, or a resend, are answered no by the rebuild, as
  recovery from a content process loss already does.
- This replaces the reload in "What a run leaves in its tabs". Amended 2026-11-11; see Decision Log.

Rationale: a reload leaves the back-forward cache in place, so a scripted page can come back with its listeners alive.
A fresh web view has no cache. Reloading a post result raises the resend refusal and leaves the scripted document
running. Telling who caused a post cannot work, since uniterm cannot see which content world started a navigation.
It no longer matters. Under ADR-15 the controller's submit is the user's submit, and the page is spared either way.
Removing every
registration on a scripted site would delete the user's own workers and push subscriptions. Converged in 1 pass.

### Who builds descriptor format 2

Original question:

"Permission descriptor format" says UTERM-005 M8 ships its two kinds at version 1 in format 2. UTERM-005 is accepted,
and its M8 says nothing about format 2. M8 starts before this proposal's M1, which also builds format 2. Format 1
refuses any kind it does not know, so M8 must change the descriptor somehow. Raised by the coherence review.

Decision: format 2 is defined in its owner, UTERM-004 "Verified artifact and run binding", with the rules settled
under "Permission descriptor format". UTERM-004 M6 builds it, since M6 already introduces format 2 for its clipboard
and host launch kinds. UTERM-005 M8 adds its two kinds at version 1. This proposal's M1 adds kinds and versions.
(addition) Amended 2026-11-11; see Decision Log.

- UTERM-004 gains format 2 in place: a version on every permission, the (kind, version) table, the refusal rules, and
  reading format 1. M6 builds the version-aware parsing before format 2 ships.
- UTERM-005 M8 adds browser navigation and browser read at version 1 to format 2. Its checks require that format 1 and
  format 2 both load, each with its own kinds.
- UTERM-004 M6 makes the UTERM-004 edit as part of its own work. The UTERM-005 M8 edit is made beside this review.

Rationale: M8 must change the descriptor, since format 1 refuses any kind it does not know. Pointing accepted M8 at
this draft's text would let shipped builds read a format no accepted document defines. Signed format 2 packages must
then be read forever. Writing format 2 into UTERM-004, which owns format 1, gives M8 an accepted definition. M6
already makes format 2 for its own kinds. Versioning it before it lands leaves one format 2, not a kinds-only format 2
and a versioned format 3 that signed packages would need forever. Moving M8 after M1 would form a cycle, since M1
tests M8's version 1 kinds. A separate proposal for a few rules would delay M8 for its own review. Converged in 1 pass.

### Result encoding

Original question:

What a read-result chunk holds, and how a script turns chunks into a value. A script value's string holds at most 4096
bytes, a record at most 64 fields with short ASCII keys, and nothing nests past 8 levels. There is no byte type. A PNG
or a PDF is binary, and a JavaScript object can have any keys. Raised by the coherence review.

Decision: every chunk is bytes, carried by a new byte type, and a JavaScript result is serialized in the caller's own
text form. Janet callers get Janet data notation, and exec drivers get JSON. (autonomous)

- An applet reply gains a byte carrier separate from `JSONValue`, which is also the stored form of applet
  descriptions. ScriptValue gains a byte-string type that reaches Janet as an immutable string. The exec wire carries
  the same bytes as a base64 string.
- Every chunk rides the byte type, text and binary alike. A chunk taken at a byte offset can split a UTF-8 sequence,
  which a ScriptValue string would cut or refuse.
- Images and PDFs are their raw bytes.
- `await-result` joins a Janet caller's chunks and reads the text with a parser that requires exactly one complete
  form. It never calls `eval` or `unmarshal`.
- The mapping from a JavaScript value is fixed. Object keys are always strings. JS `null` is `:null` in Janet and
  `null` in JSON, since a Janet struct drops a nil value. NaN and the infinities are the strings `"NaN"`,
  `"Infinity"`, and `"-Infinity"`. A Date is an ISO 8601 string in UTC.
- The app's serializer enforces the bounds that ScriptValue's limits enforced before: the per-result byte cap, and a
  nesting cap that is the same for both forms. A result past either is refused with a structured error.
- A handle reads in the form of the caller kind that made it. The byte size, the cap, and the offsets count that form.
- Skew: ScriptWire takes the next version after the one it is at when this lands. It is at 12 after UTERM-007 M5, which
  moved it from 11 and the exec protocol from 3 to 4. App and helper ship in one bundle, and a mismatch is refused
  before any call in either direction. Once UTERM-056 lands, a program on an older version keeps running, and a chunk it
  cannot read answers `replyLost` with the version it needs. Amended 2026-11-23; see Decision Log. On the exec wire, base64 appears only in replies to new commands, so this proposal
  does not move the exec protocol version, which stays at 4 unless another change moves it. Amended 2026-11-15; see
  Decision Log.

Rationale: a byte type carries images, PDFs, and UTERM-020's 16 KiB body chunks at full size. Each caller reads with
a parser it already has and trusts: Janet's core `parse`, or the driver's own JSON library. The only new code that
touches page data is a serializer written in Swift. A C JSON reader in the helper would put page text through a new
memory-unsafe parser. Janet data notation alone would make every external driver write its own reader. Base64 inside
4096-byte strings would take thousands of round trips for one PDF. Converged in 2 passes. The second pass's caveats
are folded in, and the proposal re-check covers them.

### How the app bounds browser reads in flight

Original question:

An exec driver's read-result reaches it as a member command at version 4, and each reply carries one chunk. The app
keeps at most 4 MiB of unsent output per driver, and an overflow ends the driver. Pushed applet events share that queue.
A driver that sends every read for a large result before it reads its stdin fills the queue and is ended, with its run,
its powers, and its handles. "Large results" named no bound on reads in flight, and no chunk size for the exec wire.
Filed as [20261122-exec-browser-read-result-burst-ends-driver](../bugs/20261122-exec-browser-read-result-burst-ends-driver.md).
Candidates:

- The app holds a read-result reply until the queue has room, as UTERM-055 "How the app bounds reads in flight"
  settles for captures.
- The app refuses a read with `busy` when the queue is near full. Leaves undone: every driver needs retry logic, and
  `busy` becomes the normal path for a large result, timed by the pipe.
- The documentation states a chunk size and a count of reads in flight, and nothing enforces it. Leaves undone: a
  driver that misreads it is ended.

Decision: the app holds an exec read-result reply until the outbound queue has room for it, by the hold UTERM-055
settles for capture reads.

- On the exec wire, a chunk holds at most 512 KiB of raw bytes, the ceiling UTERM-055 "The frames' fields" settles. The
  app may return fewer bytes before the end, so a driver advances by the decoded length. A ScriptWire chunk still fits
  one reply.
- The reply waits until the queue has room for it below a threshold that keeps headroom for pushed events and other
  replies. The stdin writer signals each time it frees room, and that signal releases held reads in order.
- Held reads per driver are bounded by a count, and a read past it is refused with `busy`. The count is at least this
  proposal's per-run retained result cap divided by the chunk ceiling, with a margin for repeat reads. So a driver
  that sends every read for all its handles at once is never refused.
- A held read resolves its handle when it is sent, so a handle freed meanwhile answers as a freed handle does.
  Revocation and run end free every handle, so they fail every held read.
- M3 builds the hold, since it ships exec read-result first. UTERM-055 M1 routes capture reads through the same hold,
  and raises the count to cover both result pools.
- Skew: read-result is new in M3, so the hold and its `busy` refusal ship with its first release. No meaning a version
  4 driver already relies on changes, as ADR-13 asks. `busy` is already a code a version 4 driver sees from a full
  per-tab cap.

Leaves undone: pushed events alone still end a driver that never reads its stdin, as UTERM-028 accepts.

Rationale: the user chose the hold. A driver that sends every read before reading its stdin is the obvious pattern,
since replies are matched by request ID and arrive in any order. Holding makes that driver work with no new frame, and
keeps `busy` as an abuse limit. A refusal by queue room would make every driver write retry logic, and a driver that
passes its tests could fail in the field. Documentation alone ends the obvious driver. M3 builds the hold because the
queue puts M3 ahead of UTERM-055 M1, which waits on UTERM-054 M5, which waits on M3.

## Design Decisions (Open)

None.

## Risks

- **A controller with browser script acts as the user on any site it opens** — likelihood: medium, impact: high. It
  can read pages and submit forms signed in as the user. Mitigation: browser script is its own permission, its review
  says so, and it reaches only the controller's own tabs.
- **Cookie values leave the app** — likelihood: medium, impact: high. A session cookie a controller reads works outside
  uniterm. Browser cookies with browser navigation reaches any site's cookies, HttpOnly ones included, since navigation
  can load any origin. Mitigation: browser cookies is its own permission, limited to the origins currently loaded in
  the controller's tabs, and its review text says that with navigation it reaches every site.
- **A key press may reach a web view that has not become first responder** — likelihood: low, impact: low. "Trusted
  input" now focuses a tab before a key goes to it, so the web view holds first-responder status when the key arrives.
  The earlier risk, that WebKit refuses keys delivered without it, no longer applies. What remains is a focus move that
  fails. Mitigation: M6 requires a structured error then. Amended 2026-11-27; see Decision Log.
- **Page data in replies is hostile input** — likelihood: high, impact: medium. A page controls what run-script
  returns. Mitigation: the app's serializer enforces a per-result byte cap and a nesting cap, Janet reads the text with
  core `parse` and never evaluates it, and drivers read JSON with their own parsers, per "Result encoding".
- **The capability names become a published contract** — likelihood: high, impact: medium. Scripts will depend on them,
  and renaming one breaks them. Mitigation: names are append-only and never change meaning, per "Capability names and
  the unavailable error". A dropped feature leaves the set, and a script that checks membership falls back.
- **Descriptor format 2 is a one-way door** — likelihood: medium, impact: high. Signed format 2 packages must load in
  every later build. If format 2 ships from text no accepted document holds, a later change strands those packages.
  Mitigation: UTERM-004 M6 writes format 2 into UTERM-004 and builds it with versions before it ships, per "Who builds
  descriptor format 2". An unknown kind or version refuses the whole descriptor, so a later format can only add.
- **A controller's code can outlive its run through site storage** — likelihood: low, impact: high. The rebuild ends
  every document, and new service workers are removed. Changes to other storage stay, and a page that reads them can
  act on them. A worker added on one host of a site that already had one survives. Accepted: removing site storage
  would delete the user's own data, and a worker script must be served by the site itself, so the controller needs a
  gadget on the site to plant code. A crash or force quit during a run skips the worker removal, since the run-start
  record lives only in memory.
- **Trusted input unlocks what user activation gates** — likelihood: medium, impact: medium. A page given trusted input
  can write the clipboard, open pop-ups, and enter fullscreen. ADR-09 keeps clipboard writes a separate power, and
  public WebKit API cannot block a page's clipboard write. Accepted: browser input's review text names these powers,
  and browser input is its own permission.
- **Unselected tabs may not render or take input** — likelihood: medium, impact: medium. Only the selected tab's web
  view is in the window, so a snapshot can come out blank and input can be lost. Mitigation: the M4 and M6 checks
  require each command to work there or return a structured error. Amended 2026-11-27; see Decision Log.
- **WebKit may not target a held frame, or paint off-screen content** — likelihood: medium, impact: medium.
  Mitigation: M3's and M4's first checks prove each one. A failure falls back to the main frame, or to rasterized PDF
  output, and is recorded.
- **More scripted tabs keep a marker instead of a rebuild** — likelihood: high, impact: low. Unsent input and
  post-result pages are spared from either source, so a form the controller submitted keeps its scripted page behind
  the marker. Accepted by the user on 2026-11-21. The tab's menu offers a rebuild. The earlier risk of unreliable input
  attribution no longer applies, since nothing attributes input.
- **Result chunks on the exec wire become a published contract** — likelihood: high, impact: low. External drivers will
  read the base64 field. Mitigation: it appears only in replies to commands this proposal adds, and it follows the
  browser command schema's append-only rule.
- **Large reads in flight end an exec driver** — likelihood: medium, impact: medium. A driver that sends every read
  before reading its stdin fills the 4 MiB outbound queue. Mitigation: the app holds a read until the queue has room,
  per "How the app bounds browser reads in flight". A driver that never reads its stdin can still be ended by pushed
  events, as UTERM-028 accepts.
- **The capability record holds at most 64 names** — likelihood: low, impact: low. The set is append-only, so the
  ceiling is permanent. Accepted: this proposal and UTERM-020 together need far fewer, and more would go in a new reply
  key.
- **UTERM-020 is accepted while this proposal is in design** — likelihood: high, impact: medium. Its Risks entry ties
  capability names to `uniterm/api-version`, which this proposal replaced. Its 16 KiB body chunks depend on the byte
  type from "Result encoding". Mitigation: UTERM-020 is updated when this
  proposal is accepted, per its Impacts entry.

## Milestones

### M1: Capabilities and permissions

**Status:** NOT STARTED

Starts after UTERM-005 M8.

- A capabilities command returns every capability in this proposal, each reported as available
- The reply comes from startup state, and a test shows it never waits on WebKit
- A command whose capability is off returns a structured error that names it, and the helper keeps running. The
  test turns a capability off through the applet's capability set, with no test-only switch
- The capabilities reply reaches Janet as a record keyed by keywords, and every name fits a record key
- A listed capability that cannot run now returns `failed`, never `unsupported-capability`
- The shipped helpers read `:bad-argument` from the capabilities command as an empty set
- The capabilities command needs no browser permission and takes no arguments
- Browser script, browser input, browser cookies, and browser capture are typed permissions with review text
- A controller holding only browser read and browser navigation at version 1 gets a structured error from every
  command in this proposal except capabilities
- An approval stored before these permissions existed covers none of them
- This proposal's kinds and versions join format 2 as UTERM-004 M6 builds it. An unknown version of them refuses the
  whole descriptor at load
- Each command is gated on its own permission alone. Browser script with browser read at version 1 still runs
  run-script

### M2: Page events

**Status:** NOT STARTED

- Navigation started, committed, finished, and failed, server redirect, content process terminated, dialog opened, and
  frame appeared each appear in the tab's buffer. List-frames returns the live frames
- Next-events replies at once when events past the cursor exist, and after the timeout otherwise. Its timeout has a
  maximum
- Next-events returns only the event kinds the caller's permissions cover. Hidden events neither count as dropped nor
  end a wait
- Every pending reply completes exactly once on revocation, run end, pane close, tab close, the tab leaving the
  controller, content process loss, window close, caller disconnect, and app quit. A full per-window cap refuses with
  a structured error, and one caller cannot fill it and starve another
- A Ctrl-C during next-events takes effect within next-events' maximum timeout, and never ends the helper
- An exec driver gets a deferred reply matched by request ID, and sees `unsupported-capability` as a code string
- The per-run event byte budget holds across all of a run's tabs
- List-frames and frame-appeared are refused or hidden for a caller without browser read version 2 or browser script
- A packaged `uniterm/browser.janet` file cannot shadow the built-in module
- A full buffer drops its oldest events, and the next reply reports how many
- A flood of events, such as a page that creates a thousand iframes, never pushes a reply past the reply cap and never
  blocks the main thread
- A URL over its field cap arrives cut with the truncated flag set, and a script cannot mistake it for a whole URL
- The buffer never stores event kinds the run's permissions do not cover
- Closing the tab or ending the run discards the buffer, and a later read returns a structured error
- The shipped helpers wait for one event type and call a handler per event, and both report dropped events
- `(import uniterm/browser)` works in a script run, a controller package, and the REPL, and its helpers load before the
  sandbox applies
- A reader made before a navigation sees that load's events, even when the load finishes before the first read
- A `wait-for` that meets a dialog calls `:on-dialog`, or raises with the dialog when there is none
- `wait-for` on a kind the caller's permissions hide fails clearly instead of running to its deadline
- An `each-event` handler that calls `wait-for` on the same reader neither loses nor repeats events
- A tab the controller did not open has no buffer

### M3: Page JavaScript and dialogs

**Status:** NOT STARTED

Amended 2026-11-27; see Decision Log.

- A held `WKFrameInfo` still targets its frame later, including a cross-origin frame, or the result is recorded and
  run-script goes main frame only
- Run-script passes typed arguments and returns a handle. Read-result returns the promise's value or its error. The
  slot is freed on discard, at run end, and on revocation, so a script can retry a chunk
- A burst of events between run-script and read-result never loses the result
- A script can discard a handle. A full per-tab cap refuses run-script with a structured error that says how to free
  a slot. The applet's `busy` reaches Janet as `:refused`, so the check reads the code an exec driver sees
- A `confirm()` called from a run-script appears as the next event. The script answers it, then reads the result
- A controller-world run-script on a frame after a same-origin navigation inside it returns a structured error
- A report forged by controller code cannot change another frame's ID or token, or push events past the caps
- A page-world run-script on a frame whose origin changed, or whose origin is opaque, returns a structured error. Its
  origin read uses a value page script cannot override
- Snapshot, PDF, find, and cookie handles count toward the per-tab handle cap
- Serializing a script's result happens off the main thread
- A result whose UTF-8 text crosses a chunk boundary inside a multi-byte character arrives whole
- `{a: null}`, a key such as `"foo bar"`, NaN, the infinities, and a Date each arrive in the stated mapping, in Janet
  and in an exec driver's JSON
- Escaping round-trips through `parse` for every byte sequence, under a fuzz test. Doubles such as 0.1, 5e-324, and
  1.7976931348623157e308 round-trip exactly
- `await-result` refuses text that is not exactly one complete form
- A result nested past the nesting cap, or larger than the byte cap, is refused before it is sent
- A handle made by one caller kind refuses a read by the other
- A scripted tab with an open dialog at run end keeps the dialog with the user, and is rebuilt once it is answered.
  The old web view is detached before WebKit's completion handler gets the answer, so page code never resumes
- `await-result` discards its handle on success, on error, and on interrupt. A loop of 100 run-script and
  `await-result` calls never hits the per-tab cap
- Read-result on an unfinished handle replies with something a script can tell apart from a result
- A controller-world run-script on a frame whose document changed since its ID was reported returns a structured
  error, and so
  does a frame the reporting script never ran in, such as a script-created `about:blank` frame. Neither runs in the
  main frame
- A result larger than one reply is read in chunks under its handle up to its byte cap, and refused above it. A
  malformed result is refused with a structured error
- On the exec wire, a read-result chunk's result is `{"data":d,"offset":o}`: the chunk's bytes as a base64 string, and
  the raw byte offset it starts at. These are the keys UTERM-055 "The frames' fields" settles for every exec byte chunk
- An exec read-result chunk holds at most 512 KiB of raw bytes, and fits the 1 MiB frame cap after base64 and the
  envelope. A test reads chunks shorter than the ceiling and joins them by decoded length
- An exec driver that sends every read-result for a result at the per-result cap before reading its stdin receives
  every chunk and is not ended
- An exec read past the held count is refused with `busy`, the driver is not ended, and the same read works once the
  driver reads its replies
- A held read is released when the writer frees room, with no event needed to wake it
- A held read resolves its handle when it is sent, so a handle freed meanwhile answers as a freed handle does.
  Revocation and run end fail every held read
- Run-script and injection choose the isolated or page world from two values. No call can reach uniterm's own worlds,
  and a run-script cannot post to the unsent-input tracker's handler
- Removing a controller's injections leaves uniterm's own user scripts in place
- An injected script runs at the chosen time in the chosen frames on later loads
- An alert, a confirm, and a prompt in a controller tab each appear as an event, and answer-dialog answers them
- A dialog waiting for its answer never blocks the main thread
- A tab that is not selected holds the user's view of its dialog until it is selected, and the script can answer it
  meanwhile
- A dialog in a controller tab takes the first responder as any tab's dialog does, when its pane held focus
- A click or key press that began on one dialog never answers a dialog shown after it
- A dialog dismissed at once, over the held limit or after "stop dialogs", reports as already answered, and
  answer-dialog on it returns a structured error
- In a controller tab whose run holds browser script, the dialog card says a controller drives the tab
- Injection returns an ID that remove names, each tab caps its injections, and removal applies to loads that start
  after its reply
- One owner keeps each tab's user-script list. The frame reporter runs ahead of every controller injection, and
  removing injections leaves it in place. Removing the unsent-input tracker's scripts leaves media capture, frame
  reporting, and controller injections in place
- A web view rebuilt during a live run reinstalls the controller's injections. One rebuilt after run end does not
- At run end or revocation, every scripted tab is rebuilt with no injections, unless it holds unsent input. Input
  the controller typed spares the tab as input the user typed does
- A tab spared for unsent input keeps its marker until its scripted history entry is gone
- A run-end rebuild never resends a form and never asks. A post-result page is spared from the rebuild, whether the
  user or the controller caused the post, and keeps its marker until its scripted history entry is gone
- A scripted page in the back-forward cache is gone after the rebuild, so Back loads it anew
- Service worker registrations new since run start on scripted sites are gone after run end. Registrations a site
  already had remain
- The rebuild waits only for an open dialog, and the tab shows the marker meanwhile. A download, external-app, or
  resend question open at run end is answered no
- The run-start worker record covers every site's registrations, since the scripted sites are not known yet
- App quit runs the worker removal, or records that it did not
- Whether session storage survives a run-end rebuild is recorded
- A lone surrogate in a JavaScript string maps by a fixed rule in both forms
- A result WebKit hands over far past the byte cap is refused without blocking the main thread
- The fresh web view has no controller injections and default page settings, and takes key focus back when the old
  one held it
- The run-start worker record finishes before the run's first script runs
- A tab that is not rebuilt shows the marker, and its tab menu offers "Rebuild Tab". A same-document navigation does
  not clear it, and
  going back to a cached scripted page shows it again
- A pop-up opened by a scripted document during the run is rebuilt or marked like the others
- A relaunch and an undo run none of the controller's injected scripts

### M4: Capture and page settings

**Status:** NOT STARTED

Amended 2026-11-27; see Decision Log.

- A snapshot returns a handle, and its image of the tab's viewport is read in chunks. PDF output does the same for a
  document
- A full-page snapshot renders known off-screen content, including fixed, transformed, and canvas layers, on the
  oldest supported macOS. If it does not, the result is recorded and full-page images come from rasterized PDF output
- A page with a huge content size cannot force a bitmap past the clamp on pixel area
- Retained result bytes are capped per result and per run, and a result over its cap is refused
- User agent, zoom, and print-media emulation apply to the tab and are never saved in the layout
- At run end or revocation, user agent, zoom, and print media reset before any run-end rebuild
- A snapshot of an unselected tab either works or returns a structured error
- Image and PDF encoding happens off the main thread
- Find in page returns a handle, and its match result arrives under it. The check records whether find moves the scroll
  position or shows a highlight

### M5: Cookies

**Status:** NOT STARTED

- A script reads and writes cookies, HttpOnly ones included, for an origin currently loaded in its tabs. Each call
  returns a handle, and its completion event is gated by browser cookies
- A cookie for any other origin is refused with a structured error
- Browser cookies' review text says it reaches every site when held with browser navigation, browser script, or
  browser input
- A cookie write with a parent `Domain=` attribute follows RFC 6265 domain matching, and cannot reach an origin the
  tabs have not loaded

### M6: Trusted input

**Status:** NOT STARTED

Amended 2026-11-27; see Decision Log.

- A key event delivered to a controller tab's web view reaches the page as trusted input
- Clicks, scrolls, and typing reach the page as trusted events
- A synthesized click moves focus as the user's click does, and keys then go to that tab
- A key press sent to an unfocused tab of the controller first focuses that tab, then reaches the page as trusted
  input. If the focus move fails, the result is a structured error and no key is delivered
- Input to an unselected tab either reaches the page or returns a structured error
- Browser input's review text says trusted input lets a page open pop-ups, write the clipboard, enter fullscreen, and
  play sound
- A synthesized click counts as the user's click for uniterm's own gates on downloads, pop-ups, and links to other
  apps, as in any tab
- A synthesized Cmd-W, Cmd-T, or other window key never reaches the window or the app menu

## Decision Log

- 2026-11-11: Drafted from the findings note `spec/reports/20261111-wkwebview-automation-vs-cdp.md`. The user chose a
  bounded event buffer read with a cursor, over a push stream and one-shot waits, after seeing a sketch of each. The
  user chose four new permissions, cookie access limited to the origins in the controller's tabs, and input that never
  takes focus. The user asked for shipped Janet helpers so the event loop is not verbose.
- 2026-11-11: Placing page events under browser read, page settings under browser navigation, and find under browser
  read were best guesses in the outline. The user approved the outline that listed them.
- 2026-11-11: UTERM-005 "Control" says "No command evaluates script in a page." It gets a "Superseded in part by
  UTERM-019" marker when this proposal is accepted, not while it is a draft.
- 2026-11-11: ADR check: no conflicts and no supersessions. ADR-02, ADR-03, ADR-04, ADR-05, ADR-08, and ADR-09 shape
  the settled decisions above. The capability model is a possible ADR candidate, to raise only if the inspector-bridge
  proposal makes it span every applet.
- 2026-11-11: Review start: 6 milestones, 10 settled decisions, 5 risks, no `**Live after:**` lines or row gates; out of
  scope: the private-API surface, which belongs to the inspector-bridge proposal. Proposal at commit `Draft browser
  automation for controllers`. The user asked for an autonomous review of the 9 open questions.
- 2026-11-11: Frames: a per-document frame ID uniterm assigns from WebKit's own frame info, with an origin check at use
  and a frame-appeared event. Main frame only is the fallback if M3's first check fails. (autonomous)
- 2026-11-11: Widened browser read and browser navigation: version 2 meanings carried by the descriptor format, find
  under browser capture, dialog and script events under browser script. This amends the "Permissions" placement the
  user approved in the outline. That text put all page events and find under browser read. The review found that find
  and dialog events reveal page text. (autonomous)
- 2026-11-11: Commands that wait: next-events alone waits, through a deferred applet reply. Run-script returns a
  handle, and its result sits in a per-handle slot outside the event buffer. Event kinds are gated by permission. This
  amends "Page JavaScript", which had run-script reply with the promise's value. It changes the shared applet
  contract, so UTERM-001 and UTERM-004 join Impacts. (autonomous)
- 2026-11-11: Capability names and the unavailable error: a record keyed by capability, append-only feature names,
  and `unsupported-capability` on wire `unsupported`, tied to membership in the set. The names follow these rules, not
  `uniterm/api-version`, which the Risks entry and UTERM-020's said before. (autonomous, judge)
- 2026-11-11: Permission descriptor format: format 2 with a required version per permission, each (kind, version)
  with one meaning and a coverage rule. M8's two kinds enter at version 1 in format 2. This amends UTERM-004 "Verified
  artifact and run binding" and the descriptor's "one meaning per format" rule. (autonomous)
- 2026-11-11: Content world: an isolated controller world by default, the page world on request, chosen from two
  values so no script can reach uniterm's own worlds. (autonomous)
- 2026-11-11: Buffer size and event contents: bounded by count and bytes per tab and per run, every event fits one
  reply, long fields cut with a flag, hidden kinds never stored. (autonomous)
- 2026-11-11: Large results: chunked reads under a handle, with byte caps per result and per run. Snapshot, PDF, find,
  and cookie calls finish later in WebKit, so they reply with handles too. This amends "Commands that wait", which named
  run-script alone. (autonomous)
- 2026-11-11: An unanswered dialog: it shows to the user as today, the script may answer first, and the first answer
  wins. A controller tab's dialog never takes keyboard focus. A detached pane holds back only the user's view, which
  amends "Dialogs in controller tabs". (autonomous)
- 2026-11-11: Injection lifetime: until removed, run end, or revocation. One per-tab owner of the user-script list,
  and a rebuild during a live run reinstalls the controller's injections. The owner fixes an existing bug: the
  unsent-input tracker's removal wipes the media-capture script today. (autonomous, addition)
- 2026-11-11: What a run leaves in its tabs: reload every scripted document at run end or revocation, except one
  holding the user's own input. That tab keeps a marker with a reload offer. Scripted means touched by run-script,
  loaded under an injection, or opened by a scripted document. (autonomous)
- 2026-11-11: Full-page snapshot: `takeSnapshot` over the content size, proved in M4, with a rasterized PDF as the
  fallback. No scroll-and-stitch. (autonomous)
- 2026-11-11: Helper names: a built-in `uniterm/browser` module under `uniterm/api-version`, with an explicit reader
  that fixes its start cursor and carries the caller's schema version. `wait-for`, `each-event`, `await-result`, and
  `capabilities` all take deadlines or stop rules, route dialogs to a handler or raise them, and report drops one way.
  This amends UTERM-003's "one Janet module" line. (autonomous)
- 2026-11-11: Coherence review fixes: a frame's check at use compares a per-document token kept in the uniterm
  world, not only its origin, and frame listing needs browser read or browser script. "Frames" said origin only.
  Browser input's review text names the powers user activation unlocks, such as clipboard writes and pop-ups. Format
  2 versions every permission. An exec driver skew statement joins "Permission descriptor format". The cookie risk
  says that cookies with navigation reach every site. (autonomous)
- 2026-11-11: Reach of the run-end cleanup: scripted tabs are rebuilt, not reloaded. A post-result page is exempt
  only when the user's real input reached the tab. Service worker registrations new since run start are removed from
  scripted sites. The removal touches the shared website data store. (autonomous, addition)
- 2026-11-11: Who builds descriptor format 2: UTERM-004 defines it in place and UTERM-005 M8 builds it, with M1 adding
  kinds. Both edits to accepted proposals wait for the user. (autonomous, addition)
- 2026-11-11: Result encoding: a byte type carries every chunk, with ScriptWire at version 9. JavaScript results are
  Janet data notation for Janet callers and JSON for exec drivers, with a fixed value mapping and serializer-enforced
  bounds. Exec drivers do command browser members of groups they own, so the review kept the exec skew statement.
  (autonomous)
- 2026-11-11: Re-check fixes: the frame token lives in the controller world, so a controller-world run-script checks
  it in the same call. A page-world run checks the origin only. Frame listing needs browser read version 2 or browser
  script. The run-end rebuild waits only for a dialog and shows the marker meanwhile, and answers other questions no.
  (autonomous)
- 2026-11-11: Final re-check fixes, not re-checked since the proposal loop's three passes were spent: the frame
  reporter runs in the controller world, and "Content world" no longer lists it among uniterm's own worlds. The
  stale-ID promise covers controller-world runs. A page-world run checks the origin only, and an opaque origin never
  matches. (autonomous)
- 2026-11-11: Format number conflict: uncommitted UTERM-004 M6 work in the working tree makes descriptor format 2
  add the clipboard and host launch kinds, with no per-permission version. "Permission descriptor format" and "Who
  builds descriptor format 2" assume format 2 is the versioned one. Both are provisional until the user chooses how
  the two fit. (autonomous, provisional)
- 2026-11-11: Review gate: kept every decision. The user chose that UTERM-004 M6's format 2, in progress, adopts the
  per-permission version before it lands, so M6 builds format 2 and M8 adds its two kinds to it. This settles the
  provisional format entries. The user asked for the UTERM-004, UTERM-005, UTERM-020, and queue edits in their own
  commit.
- 2026-11-11: ADR candidate (cuts across the system): a deferred applet reply never hides an effect. Written as
  ADR-11.
- 2026-11-11: ADR candidate (hard to reverse): capability names are append-only and never change meaning. Declined:
  the set is browser-only, and this proposal holds the rule.
- 2026-11-11: ADR candidate (cuts across the system): revocation ends the code a controller left in content, not only
  its commands. Declined: it rests on the run-end cleanup addition, and its final fixes went unchecked.
- 2026-11-11: ADR candidate (hard to reverse): descriptor permissions carry a version, and each (kind, version) has one
  meaning. Waits on UTERM-004 M6 landing format 2 with per-permission versions.
- 2026-11-11: Accepted by the user after the review gate. UTERM-005 "Control" gets its "Superseded in part by
  UTERM-019" marker now.
- 2026-11-11: Risk review: nine risks added from the coherence review. Format 2 as a one-way door, unselected tabs,
  the frame and snapshot spikes, input attribution, the exec base64 contract, and UTERM-020's staleness are mitigated.
  Code outliving the run through site storage, trusted input's activation powers, and the 64-name ceiling are
  accepted, each for the reason in its entry. None is high likelihood and high impact. (autonomous)
- 2026-11-11: The UTERM-004 edit the user asked for at the gate went to UTERM-004 M6's run instead. That session owns
  the file and has uncommitted edits in "Verified artifact and run binding". It agreed to define format 2 with the
  rules in "Permission descriptor format". M1's format checks moved to M6.
- 2026-11-11: Correction: "Result encoding" said the exec protocol stays at version 2. It is at version 3 today, and
  the change does not move it.
- 2026-11-15: Amended "Commands that wait". The text said the applet contract gains a pending reply, and that only
  next-events uses it in this proposal. UTERM-007 M5 built the pending reply for the text viewer's wait command, as
  ADR-11 requires. It carries a `mayWait` marker on a schema entry, which dispatch enforces, a second authority check
  before the reply goes out, failure on any control change of the pane as well as on revocation, run end, and close,
  and a cap of 64 pending replies for each window. M2 reuses it and adds its own marked command. (work-queue best
  guess)
- 2026-11-15: Amended "Capability names and the unavailable error" (the skew bullet and its rationale) and "Result
  encoding" (the skew bullet), and corrected Impacts and the "Helper names" rationale. UTERM-007 M5 changed what they
  rely on. The text said the applet contract gains a pending reply, that a command schema version matches exactly and
  new commands and reply keys leave it alone, that ScriptWire moves to version 9, and that the exec protocol stays
  where it is. The pending reply exists. A schema version is now a major and a minor, a new command or reply key
  bumps the minor, and a controller with the same major and a minor up to the applet's is accepted. ScriptWire is at
  version 12 and the exec protocol at 4, so this proposal's own bump starts from there and the exec protocol does not
  move. This changes nothing this proposal decided about the byte type or the helpers. (work-queue best guess)
- 2026-11-21: Amended "Trusted input", "An unanswered dialog", "What a run leaves in its tabs", the key-event risk,
  and the M3 and M6 checks. ADR-12 was retracted on 2026-11-20, and UTERM-037 applied that to the browser's remote
  commands. A program's operation is the same operation as the user's, and it behaves the same way. "Trusted input"
  said "synthesized input never takes keyboard focus", sent input only to a tab in a pane without key focus, and
  returned a structured error for a key-focused pane. Synthesized input now behaves as the user's does. A click moves
  focus as the user's click does, and keys go to that tab. Synthesized keys still never reach window keys or the app
  menu, which is an authority rule under ADR-14. "An unanswered dialog" said a controller tab's dialog never moves
  keyboard focus. It takes focus as any tab's dialog does. M6 said a synthesized mouse-up never counts as a user click
  for uniterm's gates on downloads, pop-ups, and links to other apps. It counts, as UTERM-037 gives a controller's
  tab the same download and handoff rules as any tab. The rationale for the run-end rebuild said a reload would
  discard unsent input against UTERM-005. The user's reload never reads unsent input. Only close, quit, and hang
  recovery do. This overrides the 2026-11-11 entries that record "input that never takes focus" and a dialog that
  "never takes keyboard focus". Those stay as history. (work-queue best guess)

- 2026-11-21: The user decided two more points, following ADR-12's retraction. A program's operation is the same
  operation as the user's, and only authority, per ADR-14, stays separate.
  First, "What a run leaves in its tabs" counted only text the user typed as a draft that spares a tab from the
  run-end rebuild. Text only the controller typed did not block a rebuild. Now unsent input counts the same from either
  source. A tab holding it is spared and keeps its marker until its scripted history entry is gone. The user accepted
  the cost. Most automation fills forms, so fewer tabs are rebuilt at run end, and they keep a marker instead. The M3
  rebuild checks match. The post-result exemption still depends on the user's real input, so input attribution stays
  for that case, and its risk is narrowed to it.
  Second, "Trusted input" said keys go to the tab a click focused, and the key-event risk said WebKit might refuse keys
  to a web view that is not first responder. Now a key press sent to an unfocused tab of the controller first focuses
  that tab, as the user's click would, and then goes to it. This matches the user's own path, since the user can type
  only into a focused tab. The risk is resolved by that rule and narrowed to a focus move that fails. M6's first check,
  which sent keyboard input back to design on failure, is dropped, and M6 gains the focus-first check. Synthesized keys
  still never reach window keys or the app menu, which is authority.
- 2026-11-21: "Trusted input" and "Reach of the run-end cleanup" now cite ADR-15 for their carve-outs. Window keys
  stay out of reach as authority. The run-end rebuild is uniterm's own work when a permission ends. Neither rule
  changes meaning.
- 2026-11-21: The user ruled on the post-result exemption. Amended "What a run leaves in its tabs", "Reach of the run-end
  cleanup", the input-attribution risk, and the M3 checks. A form a controller fills and submits is treated as if the
  user had done it. Under ADR-15, uniterm's own run-end work still treats what the program left the way it treats what
  the user left. A post-result page is spared from the rebuild whoever caused the post, and keeps its marker until its
  scripted history entry is gone. Before, only a post-result page the user's real input reached was spared, and
  uniterm noted real key and mouse events to tell the two apart. That attribution is gone, and the "Input attribution
  may be unreliable" risk with it. The same entry's earlier line that kept attribution for this case no longer holds.
  The user accepted the cost. More tabs keep a page the controller scripted, behind the marker, instead of being
  rebuilt.
- 2026-11-21: Amended "What a run leaves in its tabs", its risk "More scripted tabs keep a marker instead of a
  rebuild", and its M3 check, from UTERM-042's review. The user chose one mouse path for a tab's actions, the tab's
  right-click menu, so a click on the run-end marker does nothing. The text said "The marker offers a rebuild". The
  rebuild is now offered in the tab's menu under the marker's meaning, and as a palette command.
- 2026-11-21: Added UTERM-041 M1 and UTERM-042 M2 to Dependencies, for M3. UTERM-041's Impacts already said M3 waits
  on UTERM-041 M1, but this list left it out. UTERM-042 M2 builds the only way to choose "Rebuild Tab". Without it, M3
  would ship the run-end marker with no way to rebuild the tab.
- 2026-11-21: Scheduled as M1-M2, M3, and M4-M6 in queue.md. M3 is its own row because it waits on UTERM-041 M1 and
  UTERM-042 M2.
- 2026-11-22: (autonomous, addition) From UTERM-055's review. "Result encoding" said the exec wire carries chunk bytes
  as a base64 string and named no key for it. M3 ships that first, so an implementer would have picked a permanent key.
  UTERM-055 "The frames' fields" names the result keys `data` and `offset`, and M3 gained a check for them. Impacts
  gained a UTERM-055 line.
- 2026-11-23: From the triage of 20261122-exec-browser-read-result-burst-ends-driver. The user chose that an exec
  read-result reply waits until the outbound queue has room, by UTERM-055's capture hold, over a `busy` refusal at a
  full queue and a documented bound. Added "How the app bounds browser reads in flight", a Risks entry, and M3 checks
  for the hold.
- 2026-11-23: (autonomous) Mechanisms under the user's choice. M3 builds the hold, since the queue puts UTERM-055 M1
  after M3, and the option offered had M3 wait on UTERM-055 M1. The exec chunk ceiling is UTERM-055's 512 KiB, so one
  ceiling sizes the held count. One count per driver covers both result pools, so a driver that sends every read for
  all its handles is never refused. UTERM-055 M1 raises it for capture reads.
- 2026-11-23: From UTERM-056's acceptance. "Result encoding" said "a mismatch is refused at the hello in either direction".
  That holds only for the command's own messages.
- 2026-11-27: The user retired the `detach` and `reattach` lifecycle events, and ADR-05 is amended to match. No pane is
  ever detached, so every detached-pane case here is gone. The cases for a tab that is not selected stay.
  - Amended "Dialogs in controller tabs". It said "A detached pane holds back the user's view of its dialogs until
    reattach, per ADR-05." A tab that is not selected holds back the user's view now, as the browser's dialogs already
    do.
  - Amended "An unanswered dialog". It said "The dialog appears when its tab is selected and its pane attached", and "A
    detached pane holds back only the user's view, per ADR-05. A script may answer a dialog in a detached pane".
  - Amended two risks. One said a focus move fails "such as in a detached pane". The other was titled "Unselected or
    detached tabs may not render or take input".
  - Amended M3. Its check said "A detached pane holds the user's view of its dialog until reattach, and the script can
    answer it meanwhile". It now checks the same for a tab that is not selected.
  - Amended M4 and M6. Their checks said "an unselected tab or a tab in a detached pane".

## References

- Findings note: `spec/reports/20261111-wkwebview-automation-vs-cdp.md`
- [ADR-02](../adr/ADR-02-pane-tree-nodes-have-stable-ids.md): no addressing by index
- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): restore never runs a controller's scripts
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): synthesized keys never reach window keys
- [ADR-05](../adr/ADR-05-applet-lifecycle-events-and-applet-responses.md): applet lifecycle events
- [ADR-08](../adr/ADR-08-ui-responsiveness.md): no main-thread wait on a script or WebKit
- [ADR-09](../adr/ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): each power is its
  own permission
- [ADR-11](../adr/ADR-11-deferred-applet-replies-never-hide-effects.md): a deferred applet reply never hides an
  effect
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): a controller controls what it opened
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): a program's operation is the user's; authority and
  uniterm's own run-end work are its carve-outs
