# UTERM-055: Exec Drivers Capture Panes

**Status:** accepted
**Created:** 2026-11-22
**Updated:** 2026-11-27

## Dependencies

- UTERM-054, for the host capture, its tab scope, its reason kinds, and the pane capture power
- UTERM-028, for the per-run grant a driver's powers use, a driver's own applet commands after a revoke, and the drop
  of queued frames on revocation
- UTERM-063: the exec wire is at version 0, so the capture frames land in place after UTERM-063 M2
- UTERM-019, for the base64 field shape its exec byte results use, and M3 for the read hold M1 reuses

## Impacts

- UTERM-054 — "Where a program's capture command lives" and M6. This proposal is where exec drivers' capture lands,
  including the browser snapshot UTERM-019 planned for them.
- UTERM-019 — "Full-page snapshot", the exec skew statement, and its result chunks reaching drivers as base64. Exec
  drivers' browser snapshot moves here. "The frames' fields" binds the `data` and `offset` keys of UTERM-019's exec
  read-result chunks, and UTERM-019 M3 gains a check for them.
- UTERM-028 — its command frames and this proposal's capture frames both land in place at exec version 0. Neither
  adds to the hello.

## Summary

An external exec driver captures a pane or tab, and the browser's full page, through the host capture UTERM-054 adds
for the user and for scripts. The capture frames land in place at exec protocol version 0, under
UTERM-063. The PNG bytes read back in base64 chunks that fit the exec frame cap.

## Motivation

UTERM-054 gives the user and Janet scripts a pane capture, but external exec drivers cannot reach it. An exec frame
type the app does not know ends the driver as malformed. ScriptWire calls do not
reach exec drivers.

UTERM-019 planned a browser snapshot for exec drivers that command browser members of groups they own. UTERM-054 moves
that snapshot into its host capture, so exec drivers would lose it. The user chose to keep exec capture as its own
proposal instead.

The map viewer and the image viewer accept exec drivers today, and UTERM-054 makes both capture-capable. So a driver
capturing its own pane is a live case. The frames this proposal adds become a published contract once the exec wire
is declared stable.

## Design Decisions (Settled)

### Exec capture is its own proposal

Decision: exec drivers' capture lives here, apart from UTERM-054. It covers every applet that has UTERM-054's capture
capability, and the browser's full page.

Rationale: the user chose this. Exec capture builds on UTERM-028's driver grant, and its frames are a wire contract
that deserves its own review. Amended 2026-11-26; see Decision Log. UTERM-054's user and script capture does not wait for it.

### Capture frames land in place at version 0

Decision: the exec wire gains three frames, capture, read-result, and discard, in place at protocol version 0, under
UTERM-063. Amended 2026-11-26; see Decision Log.

- Each read-result chunk carries bytes in UTERM-019's base64 field shape, so a driver has one byte encoding.
- A chunk is sized so its base64 form and envelope fit the 1 MiB frame cap.
- Errors use UTERM-054's append-only reason kinds.
- There is no image clipboard write. A program never copies a capture to the clipboard, as UTERM-054 settles.
- The hello is unchanged, and no frame that exists today changes meaning.
- A driver discards each handle it no longer needs, under ADR-11. Revocation, run end, and pane close free the rest.

Rationale: at version 0 a change lands in place, and there is nothing to negotiate. A host operation has been a new
frame type before, as `layout` and the clipboard were. New frame types change no existing meaning, so UTERM-063's rule
that a changed meaning is refused needs no retired name here.

### Exec capture follows UTERM-054's rules

Decision: an exec driver's capture goes through UTERM-054's host capture. Its tab scope, its target states and their
refusals, its pending state and cancel, its one failure notice per pane per run, its time bound, and its caps are
UTERM-054's. A refusal decided before the capture starts goes in the reply only.

Rationale: one capture path serves every caller, so behavior cannot drift by transport, as ADR-15 asks.

### Version skew

Decision: the deploy units are the app and external exec drivers.

- New driver, old app: an app built before this proposal refuses a capture frame by name, under UTERM-063 M2's strict
  decoder, before any effect.
- Old driver, new app: a driver that sends no capture frame runs as before. The app sends it nothing new.
- A newer app can send a reason kind that a driver built earlier has never seen, since UTERM-054's reason kinds are
  append-only. A driver that does not know a reason acts on the error's `code`, and every capture error means nothing
  was captured. The exec wire's documentation states this rule.
- The frames carry a compatibility promise only once uniterm's maintainers declare the exec wire stable.

### Which grant and targets an exec driver captures under

Original question:

An exec driver has no verified identity, so ADR-14 P9 lets it keep no remembered approval. Each run gets its own group
owner, and member commands check ownership against that driver owner. A driver's browser and clipboard powers are per
run: it asks for them in Pending Requests, and Revoke and run end clear them. UTERM-028 rejects inheriting a
controller's approval, since nothing links a driver to the run that covered its launch. A driver the user starts with
Run has no controller at all. So every candidate that needs a controller's descriptor grant cannot be built for a
driver. Candidates:

- A per-run capture power the driver asks for in Pending Requests, as its browser powers are, with Allow Once and Allow
  for This Run, held on the attachment. Its targets are the driver's anchor, its source pane under ADR-14 P2, plus
  remote-controlled members of groups this run owns. The tab scope uses the driver's owner as the caller. Revoke and
  run end end the power.
- The driver captures under its controller's grant, with the pane capture power in the controller's descriptor.
  Needs a descriptor that a user-launched driver lacks, and contradicts UTERM-028's rationale.
- A separate exec capture power in the descriptor, so a controller can grant capture to scripts and not to its driver.
  Same flaw as the controller's grant, and no one is named who would set it.
- The driver's own pane only, under the per-run power or under none. Leaves undone: the browser snapshot the user chose
  to keep, since a driver's browser panes are group members, not its anchor.

Whichever is chosen must also settle two cases. Does capturing the driver's own anchor need the power too? And can the
driver still capture its anchor after Revoke, since UTERM-028 leaves a driver its own applet commands and events after
a revoke? The image viewer promises that nothing from a file the caller may not read leaves the pane, and an exec
driver holds no path-reading power. A driver that captures an anchor showing a user-opened image would get pixels its
events withhold. Filed for UTERM-054 as
[20261122-capture-bypasses-image-viewer-read-scope](../bugs/20261122-capture-bypasses-image-viewer-read-scope.md).

Decision: a per-run capture power, which the driver asks for through the Pending Requests route its clipboard and
browser powers use. The panel offers Allow Once and Allow for This Run, and the power is held on the run's attachment.
Its targets are the driver's anchor and the remote-controlled members of groups this run owns. The tab scope uses the
driver's group owner as the caller. (autonomous)

- A capture of the anchor needs the power too. Nothing about a capture is free because the pane is the driver's own.
- Revoke and run end end the power everywhere, the anchor included, and fail every pending capture. The driver keeps
  its own applet commands and events after a revoke, as UTERM-028 settles.
- A driver's caller holds no file read scope. A driver's capture follows whatever UTERM-054 settles for the read-scope
  bug, which covers the image viewer and the map viewer's file layer. If that resolution refuses a capture outside the
  caller's read scope, a driver's capture of a pane showing a user-opened file is refused.
- The power's panel text says a capture reads whatever the pane shows.
- The power's bound under ADR-14 P15 is its targets, the run, and UTERM-054's per-result and per-run caps, one pending
  capture per pane, and time bound.

- M1 waits for UTERM-054's resolution of the read-scope bug, so no driver capture ships while the image viewer's
  contract says nothing from such a file leaves the pane. Amended 2026-11-22; see Decision Log.

Rationale: this is the only candidate that keeps the browser full-page snapshot the user chose and also meets
UTERM-054's rule that a capture needs an explicit, revocable grant, even of the source pane. Both exec-capable applets
can show a user-opened file their events withhold from a driver, so a free anchor capture would read it without
consent. It would also leave a read standing at the badge where the user chose Revoke, against UTERM-028's rule that
revocation ends a power everywhere, the anchor included. Capturing only the anchor drops the browser snapshot, since a
browser reaches a driver only as a group member. A controller's descriptor grant cannot be built for a driver started
with Run, and UTERM-028 rejects handing one requester's grant to another process. A separate descriptor power has the
same flaw, and no one is named who would set it. Converged in 1 pass.

### How a capture's held reply reaches a driver

Original question:

UTERM-054's ScriptWire capture holds its reply until the PNG is ready, which ADR-11 allows for a command that only
reads. UTERM-019's exec skew statement says a deferred reply reaches a driver matched by request ID, as layout replies
do. Candidates:

- The capture frame's reply is deferred and matched by request ID, and it carries a result handle once the PNG is
  ready. The driver reads chunks with read-result and frees the handle with discard.
- The capture frame replies at once with a handle, and a completion event on the driver's pane event stream names it.
  A capture only reads, so ADR-11 does not require this.

Decision: the capture frame's reply is held and matched by request ID, as layout replies are. It
carries a result handle once the PNG is ready. The driver reads chunks with read-result and frees the handle with
discard. Revocation, run end, pane close, the user's cancel, and the time bound fail the held reply with a structured
error. (autonomous)

- The host holds the reply, not the applet's dispatcher, so the host re-checks authority at completion itself.
- A driver cannot cancel its own pending capture. The user's cancel and the time bound bound it, as for ScriptWire. The
  exec wire's documentation says so.

Rationale: the held reply needs no new mechanism. The exec wire already matches out-of-order replies by request ID, and
layout and Pending Requests replies already wait. It keeps the three frames this proposal settles, and it has the same
shape as UTERM-054's ScriptWire capture. A pushed completion adds a fourth published frame for no effect ADR-11 needs.
The driver's event stream cannot carry it for members, since only the anchor's applet feeds that stream. Replying at
once and then waiting or reading "not ready" also adds a frame or a state, and it is ADR-11's shape for effects, which a
capture has none of. Converged in 1 pass.

### The frames' fields

Original question:

M1 must not invent a permanent contract, as UTERM-028 settled its command frames' JSON for the same reason. The frames
need these fields settled:

- Capture: the target pane, which capture of content, pane, or full page, and which tab.
- The capture reply: the handle, the byte size, whether the image was clamped, and its density.
- Read-result: the handle, and an offset in raw bytes rather than base64 characters. The reply's chunk carries bytes as
  a base64 string, as UTERM-019 does.
- The chunk size, and the discard reply.
- Where the reason kind goes. The exec error frame carries only `code` and `message` today.

Candidates: mirror the ScriptWire capture calls' fields one for one, so both transports name the same things, or give
the exec frames their own field set in the style of UTERM-028's command frames.
Amended 2026-11-27; see Decision Log.

Decision: the exec frames are settled here as concrete JSON, in the style of UTERM-028's command frames. Their chunk
keys are the exec spelling of every byte chunk, so UTERM-019's browser read-result uses them on the exec wire too.
(autonomous, addition)

- Capture: `{"type":"capture","id":n,"pane":p,"of":"content","tab":t}`. `pane` is a node ID, and leaving it out
  names the anchor. `of` is `"content"`, `"pane"`, or `"full-page"`. `tab` is the string tab reference the applet's
  own commands answer, and leaving it out names the selected tab.
- The held reply's result: `{"handle":h,"size":n,"clamped":false,"scale":2}`. `handle` is a string. `size` is the
  PNG's byte count. `scale` is the delivered image's pixels per point after any clamp, which is the density the PNG
  records. So `clamped` with `scale` tells a cropped image from a scaled one.
- Read-result: `{"type":"read-result","id":n,"handle":h,"offset":o}`, where `offset` counts raw bytes. Its result is
  `{"data":d,"offset":o}`. `data` is the chunk's bytes as a base64 string, and `offset` echoes the read, since replies
  arrive in any order.
- A chunk holds at most 512 KiB of raw bytes, which fits the frame cap after base64 and the envelope. The ceiling is
  not an exact size. The app may return fewer bytes before the end, so a driver advances by the decoded length, and a
  read is complete when the offset plus its length reaches `size`.
- Discard: `{"type":"discard","id":n,"handle":h}`. Its result is an empty object.
- The error object gains an optional `reason` key beside `code` and `message`, carrying UTERM-054's
  reason kind. Each reason rides one fixed `code` from the existing set. A driver that does not know a reason still
  acts on its code, so it can tell `busy` from a refusal.
- UTERM-019's browser read-result reaches a driver as a member command. Its exec result carries a chunk
  under the same `data` and `offset` keys. That binds a key UTERM-019 leaves unnamed, before UTERM-019 M3 first ships
  exec base64.

Rationale: the JSON is settled before M1 builds it, so no implementer picks the contract, as UTERM-028 settled its
command frames. The settled base64 decision promises a driver one byte encoding. UTERM-019
names no key for its exec chunks, and its M3 ships them before M1 here can start, so binding the keys here is the only
way that promise holds. Mirroring ScriptWire has little to mirror: ScriptWire is positional binary, with no field names,
no reason slot, and a numeric tab ID. A ceiling keeps a smaller chunk open to a later app, where an
exact size would let a driver that reads in parallel join chunks wrongly. A driver-chosen length was left out, since no
caller needs it and a later change can add it under a new key. A reason inside `code` would lose the class an unknown reason rides on.
Converged in 1 pass.

### How the app bounds reads in flight

Original question:

Retained outbound bytes are capped at 4 MiB and a frame at 1 MiB, and an overflow ends the driver. Pushed applet events
share that queue. A driver that sends five read-results before it reads its input can be ended, and its capture lost.
Candidates:

- The app refuses a read with `busy` when the retained outbound bytes plus the chunk would pass the cap. The bound
  accounts for pushed events.
- The app bounds read replies in flight per driver, and refuses the next read with `busy` past the bound. Leaves
  undone: events share the queue, so a count alone can still overflow.
- The chunk size is fixed small enough that a stated count of reads fits beside events. Leaves undone: a burst of
  events can still overflow.
- The exec wire's documentation says how many reads may be in flight, and nothing in the app enforces it. Leaves undone:
  a driver that misreads it is ended.

Decision: the app holds a read-result's reply until the outbound queue has room for it below a threshold that keeps
headroom for pushed events and other replies. Then it sends it. Holding is allowed, since a read only reads. Held reads
per driver are bounded by a count, and a read past the count is refused with `busy`. (autonomous) Amended
2026-11-23; see Decision Log.

- The stdin writer signals the channel each time it frees room, and that signal releases held reads in order. Without
  it, a driver that drains its stdin while no event arrives would wait forever.
- The count is at least the sum of the per-run retained result caps of every pool a driver reads, capture results and
  UTERM-019's browser results, divided by the 512 KiB chunk ceiling, with a margin for repeat reads. A driver that
  sends every read for all its handles at once is never refused.
- The exec wire's documentation promises a floor on held reads, never an exact count. It says a read past the bound is
  refused with `busy`, and is safe to send again after the driver reads its replies. The threshold is not published.
- Revoke, run end, and pane close fail every held read. A read-result reply the app queued and has not yet written is
  dropped at Revoke, and an error reply for its request ID takes its place, in order. That is queued work under ADR-14
  P11, as UTERM-028 drops queued invocation frames.
- UTERM-019 M3 builds the hold for its browser read-result on the exec wire, per UTERM-019 "How the app bounds browser
  reads in flight", since M3 ships first. M1 routes capture reads through the same hold, and one count covers both.

Leaves undone: pushed events alone still end a driver that never reads its stdin, as UTERM-028 accepts.

Rationale: a driver that sends every read of a capture before reading its stdin is the obvious pattern, since `offset`
is echoed for replies in any order. Five chunks of about 683 KiB fill the 4 MiB queue, so it is the common case for a
large capture. Holding the read makes that driver work with no wire change, and leaves `busy` as an abuse limit. A
refusal by byte count would make `busy` the normal path for any capture over about 3 MiB, timed by the pipe, so every
driver needs retry logic and a driver that passes its tests can fail in the field. Shrinking chunks to the room left
still needs `busy`, and splits a capture into many small frames under load. A count of replies alone, or a small fixed
chunk, can still overflow beside events. Documentation alone ends the obvious driver. Pausing the driver's inbound
frames moves the overflow to the inbound buffer, or deadlocks a single-threaded driver. Covering UTERM-019's exec
reads from here would give its drivers a new `busy` refusal. It would also bind UTERM-019's chunk
size and size the count across its result pools. UTERM-019 M3 is not started, so it can take the same hold in its own
design, from its first release. Converged in 1 pass.

## Design Decisions (Open)

None.

## Risks

- **The capture frames become a published contract when the exec wire is declared stable** — likelihood: high,
  impact: medium. Mitigation: they land at version 0, where they may change in place under UTERM-063's rules until
  then. They add frame types and change no existing meaning, and they are settled here before M1 builds them.
- **Large reads in flight end the driver** — likelihood: medium, impact: medium.
  Mitigation: chunks are sized against the frame cap, and the app holds a read until the outbound queue has room, per
  "How the app bounds reads in flight". The exec wire's documentation states the bound.
  UTERM-019 M3 builds the same hold for browser reads.
- **A driver with no verified identity reads what a pane shows** — likelihood: medium, impact: high.
  Mitigation: capture follows UTERM-054's tab scope, and needs a per-run power for every target, the anchor included,
  so a driver's reach is bounded. "Which grant and targets an exec driver captures under" settles the power and its
  targets.
- **A driver's capture reads a user-opened file its events withhold** — likelihood: medium, impact: high.
  Mitigation: a capture needs the per-run power, whose panel text says a capture reads whatever the pane shows. A
  driver's caller holds no read scope, so UTERM-054's rule for
  [20261122-capture-bypasses-image-viewer-read-scope](../bugs/20261122-capture-bypasses-image-viewer-read-scope.md)
  applies to drivers as written. A capture leaves out or refuses what the caller may not read, so a driver's capture
  of a user-opened image in its anchor is refused, and a map capture leaves out the file's pins. The live case narrows
  to the driver's own map pins and browser members. Amended 2026-11-26; see Decision Log.
- **The design rests on three unbuilt proposals and a proposed ADR** — likelihood: high, impact: medium.
  Mitigation: M1 waits for UTERM-028 M1 and UTERM-054 M2, M3, and M5. M5 reaches UTERM-019's byte type and exec
  base64. Following UTERM-054's rules also rests on ADR-15, which is proposed. A change to any of their capture or
  frame shapes reopens the matching decision here.
- **M1 rests on UTERM-054 M5's read-scope rule** — likelihood: medium, impact: medium.
  Mitigation: UTERM-054 settled the rule on 2026-11-26, and its M5 builds it before M1, which waits for M5. The revoke
  drop of queued replies also rests on UTERM-028 M1's queued-frame drop, which M1 already waits for.

## Milestones

### M1: Exec capture frames

**Status:** NOT STARTED

Waits for UTERM-063 M2, for UTERM-028 M1, and for UTERM-054 M2, M3, and M5. M5 builds the read-scope rule for
[20261122-capture-bypasses-image-viewer-read-scope](../bugs/20261122-capture-bypasses-image-viewer-read-scope.md).

- A driver sends capture, read-result, and discard at exec protocol version 0, and the hello is unchanged
- A driver that sends no capture frame runs as before
- A capture from an exec driver follows UTERM-054's tab scope, target states, notice bound, time bound, and caps
- A read-result chunk fits the frame cap after base64, under the `data` and `offset` keys "The frames' fields" settles
- An exec driver's browser full-page capture of a tab its layout opened, in a remote-controlled browser member of a
  group this run owns, returns the image. A capture of a tab the user owns in that member is refused
- Revocation, run end, and pane close fail a pending capture and free its handle, under ADR-11
- The exec wire's documentation, beside UTERM-028's command frames, covers the frames, their errors, the rule
  for unknown reason kinds, and the bound on reads in flight
- No frame that exists before this milestone changes meaning
- A second capture of a pane with a pending capture is refused, as UTERM-054's one pending capture per pane settles,
  and held captures never count against the Pending Requests panel's rows
- A driver's failure notice names the driver as pane chrome does, by executable and process ID
- A capture of a member pane needs the member to be remote-controlled and owned by this run
- A capture of the anchor needs the capture power, and is refused after Revoke while the driver's own applet commands
  and events keep working
- A driver holding only the capture power is listed at its anchor, Revoke ends the power, and run start and run end
  clear it
- Each capture's Pending Requests detail names its target pane and whether it captures content, the pane, or the full
  page
- A pending driver capture fails and frees its slot when, before completion, the run is revoked or ends or the target
  closes. A member's capture also fails when the member loses remote control, its group's owner changes, or its control
  generation changes. The anchor's capture does not fail on a mode change, since the anchor counts whatever its mode
- Encoding a chunk reply stays within ADR-08's main-thread budget, or runs off the main thread
- The Pending Requests row offers Allow Once and Allow for This Run, and its text says a capture reads whatever the
  pane shows
- Allow Once covers one capture, whose completion re-check passes and whose handle still reads
- A capture of `"of":"full-page"` on a pane that is not a browser is refused with a named reason, and a `tab` on an
  applet with no tabs is refused the same way
- The exec wire's documentation says a driver cannot cancel its own pending capture
- After a clamp, `scale` equals the density the PNG records
- A capture that finishes after its run ended frees its slot and sends nothing
- The frames match "The frames' fields" exactly, and every reply the app writes fits the 1 MiB frame cap
- `tab` takes the string tab reference the applet's commands answer, and a capture of `"of":"pane"` that names an
  unselected tab is refused, never selected
- A `pane` set to the anchor's node ID captures the anchor, as leaving it out does
- The exec wire's documentation lists the fixed `code` each reason rides on, and a test pins the pairs
- A handle is scoped to the run's attachment. Reading or discarding another driver's handle, an unknown handle, or one
  already freed is refused alike, and the documentation says a handle freed by pane close answers the same way
- A test reads a capture whose chunks come back shorter than the ceiling, and joins them by decoded length
- A driver that sends every read of a capture at the per-result cap before reading its stdin receives every chunk and is
  not ended
- A read past the held count is refused with `busy`, the driver is not ended, and the same read works once the driver
  reads its replies
- Capture reads go through the hold UTERM-019 M3 builds, and share its count. A driver that sends every capture read
  and every browser read for all its handles before reading its stdin is never refused
- Run end and pane close fail held reads, as Revoke does
- A held read is released when the writer frees room, with no event needed to wake it
- A held read resolves its handle when it is sent, so a handle freed meanwhile answers as a freed handle does
- Revoke fails every held read, and drops every read-result reply queued and not yet written, sending an error reply
  for each dropped request ID in order. A frame being written when the revoke lands is neither cut short nor sent twice
- Revoke drops only capture read-result replies. Other queued replies, held capture replies, discard and layout
  replies, and events stay queued in order, and each replacing error carries a fixed `code` and `reason`
- The exec wire's documentation limits "nothing was captured" to errors on the capture frame. It says a read-result
  `busy` leaves the handle readable, and that a read-result error after Revoke means chunks already received are partial
- UTERM-054's time bound starts when the capture starts, not when the power is asked for, and a denied or withdrawn
  ask fails the held reply with a structured reason

## Decision Log

- 2026-11-22: Filed from the UTERM-054 review. The user dropped exec capture from UTERM-054, then chose to bring it back
  as its own proposal when the review found that UTERM-019's exec browser snapshot would be lost. The frame list,
  base64 shape, and skew analysis come from that review's critique.

- 2026-11-22: Revised after the draft's design critique. Motivation said no exec-capable applet ships. The map viewer
  and image viewer accept exec drivers today, so it now says deployed drivers may exist. "Which grant and targets an
  exec driver captures under" rested on a controller's grant that drivers never hold. It now states the per-run power
  model, adds a per-run capture power candidate, and names the two anchor cases. Added the open questions "The frames'
  fields" and "How the app bounds reads in flight". "Version skew" replaced its stored-grant bullet, since driver
  grants are never stored, with the rule for unknown reason kinds. Risks gained a driver's read of a pane and the
  proposed ADR, and the version 4 risk is now rated medium.

- 2026-11-22: The re-check converged. Routed three checks and folded its notes into the grant and read-bound
  questions, including the image viewer read-scope gap, filed for UTERM-054.

- 2026-11-22: Review start: 1 milestone, 4 settled decisions, 5 risks, no `**Live after:**` lines or row gates, at
  commit "Fold UTERM-055's re-check notes into its open questions". One out-of-scope statement: a program never copies
  a capture to the clipboard. The user asked for an autonomous review of all 4 open questions.
- 2026-11-22: (autonomous) An exec driver captures under a per-run capture power from Pending Requests, with Allow
  Once and Allow for This Run. Its targets are the anchor and the remote-controlled members of groups the run owns. The
  anchor needs the power too, and Revoke ends it there. A driver's caller holds no read scope, so UTERM-054's read-scope
  resolution applies to drivers. Converged in 1 pass.
- 2026-11-22: (autonomous) A capture's reply is held and matched by request ID, and carries a handle once the PNG is
  ready. Converged in 1 pass. A reply at once with a later wait frame was ranked and could not win, since it adds a
  frame.
- 2026-11-22: (autonomous, addition) The exec frames are settled as concrete JSON. Capture names `pane`, `of`, and
  `tab`. Its reply gives `handle`, `size`, `clamped`, and `scale`. Read-result returns `data` and `offset`, with a 512
  KiB ceiling per chunk. The error object gains `reason`. The addition: UTERM-019's exec read-result chunks use the same
  `data` and `offset` keys, which UTERM-019 left unnamed. UTERM-019 M3 gains a check for them. Converged in 1 pass.
- 2026-11-22: (autonomous, addition) The app holds a read-result reply until the outbound queue has room, released by
  a drain signal from the writer. Held reads are bounded by a count of at least the per-run cap over the chunk ceiling,
  with `busy` past it. The addition: the hold covers UTERM-019's exec read-result replies too, built in M1. Converged
  in 1 pass. The recommendation moved from a byte-count refusal, since that makes `busy` the timing-dependent normal
  path for any large capture.
- 2026-11-22: Growth question. The coherence pass found that covering UTERM-019's browser reads with the hold forced a
  version 4 skew case, a chunk ceiling bound into UTERM-019, and a count sized across two result pools. The user
  narrowed the hold to capture reads. Amended "How the app bounds reads in flight": it said the hold covers UTERM-019's
  browser read-result replies on the exec wire too, and that M1 builds it for both. UTERM-019's overflow is filed
  against it as 20261122-exec-browser-read-result-burst-ends-driver.
- 2026-11-22: (autonomous) Coherence review fixes. Amended "Which grant and targets an exec driver captures under":
  its Leaves undone line said what a driver may capture of a user-opened file waits on UTERM-054's read-scope
  resolution, with no gate. M1 now waits for that resolution, and for UTERM-054 M2 and M3, which build the browser full
  page and map capture. Amended "How the app bounds reads in flight": it said Revoke, run end, and pane close fail held
  reads. Queued, unwritten read-result replies are now also dropped at Revoke, with an error reply in their place,
  under ADR-14 P11. Amended "Version skew": it said a driver treats an unknown reason as a refusal, which disagreed with
  "The frames' fields". It now says a driver acts on the code. M1 gained checks routed from the review.
- 2026-11-22: (autonomous, addition) Amended "Version skew": it said a version 5 driver ignores the longer list by
  UTERM-028's hello rule. That rule covers unknown fields, not unknown values. UTERM-028 M1's documentation now says a
  driver picks a version it knows and ignores the others, and its M1 gains a fixture for it.
- 2026-11-22: (autonomous) Risk review. Added "M1 waits on a bug no proposal schedules", mitigated by the bug naming
  the gate. No risk is rated high likelihood and high impact. The proposal loop converged in 2 passes.
- 2026-11-22: Review gate: kept all. The user kept UTERM-019's exec chunks on the same `data` and `offset` keys, and
  the UTERM-028 documentation rule that a driver picks a version it knows from the offered list.
- 2026-11-22: The user accepted the proposal. No decision earns an ADR: the driver's grant and targets are ADR-14's,
  wire compatibility is ADR-13's, and the frames, the held reply, and the read hold are scoped to this exec version.
- 2026-11-22: Scheduled as UTERM-055 M1 in queue.md.
- 2026-11-23: From the triage of 20261122-exec-browser-read-result-burst-ends-driver. The user chose that UTERM-019's
  exec read-result reuse this proposal's read hold. Amended "How the app bounds reads in flight": it said the hold
  covers capture reads only and UTERM-019 settles its own fix, and it sized the count from one per-run cap. UTERM-019
  M3 now builds the hold, since it lands before M1. M1 routes capture reads through it, and the count covers both result
  pools. (autonomous) M3 building the hold and the summed count are mechanisms under the user's choice. The risk "Large
  reads in flight end the driver" no longer says browser bursts can end a driver. M1 gained a check for the shared
  count, and Dependencies names UTERM-019 M3's hold.
- 2026-11-26: The capture frames land in place at exec protocol version 0, per UTERM-063, since UTERM-028 no longer
  offers versions. "A new exec protocol version carries capture" is now "Capture frames land in place at version 0",
  with the frames unchanged. "Version skew" rests on UTERM-063 M2's refusal by name. Removed the risk that a version 4
  driver rejects the longer hello. UTERM-028 stays a dependency for its driver grant and its queued-frame drop, and M1
  now also waits for UTERM-063 M2. M1 lost its version offer checks and its version 5 fixture.
- 2026-11-26: UTERM-054 settled its read-scope question: a capture leaves out or refuses what the caller may not read.
  M1 no longer waits on an unsettled bug, only on UTERM-054 M5, which builds the rule. The risk that M1 waits on a bug
  no proposal schedules became a risk on that rule.
- 2026-11-27: Brought in line with UTERM-063 at the user's direction. "The frames' fields" said UTERM-028 "settled its
  version 5 JSON" and offered "their own field set in the version 5 style". There is no exec version 5, since the exec
  wire stays at 0 and UTERM-028's command frames land in place. Both phrases now name UTERM-028's command frames. The
  rest of the proposal was read and already says the frames land in place at version 0.

## References

- ADR-11: deferred applet replies never hide effects
- ADR-13: external wires stay compatible across versions
- ADR-14: a controller controls what it opened
- ADR-15: a program's operation is the user's
