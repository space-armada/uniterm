# UTERM-065: Exec Drivers Read Paths in a Scope

**Status:** accepted
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- UTERM-004: exec drivers, their launch approval, the Pending Requests panel, and the exec wire
- UTERM-015 M4: the path-reading power, its scope type, its scoped open, and its recheck at delivery
- UTERM-063: the exec wire is at version 0, so the request frame lands in place after UTERM-063 M2

## Impacts

- UTERM-006 — "Control levels" and M5: M5's driver `show` and stepping wait on this proposal's M1, and its `shown`
  with a path waits on M2. M5 adopts the driver's read access in the image viewer's replies and `shown`.
- UTERM-015 — Decision Log, 2026-11-16, best guess 8 ("An exec driver brings no opens"): a driver that holds this grant
  brings opens. UTERM-015 is implemented, so its text stays, and it gains a "superseded in part by UTERM-065" Decision
  Log line when this proposal is accepted.
- UTERM-028 — "How a driver gets the power": this grant follows the same per-run pattern, and shares its revocation.
  Both need the panel to offer Allow for This Run with no Allow Once.
- UTERM-008, UTERM-040 — the map withholds a file pin's ID from every program caller, with no check of read access.
  This proposal hands the map the driver's access, but leaves its rule unchanged. A driver sees file pins only once
  UTERM-008 or UTERM-040 makes the rule read access.
- UTERM-054, UTERM-055 — the bug `20261122-capture-bypasses-image-viewer-read-scope` is an open question in UTERM-054.
  A capture is checked by the host, not in an applet's reply or event, so "One read access for every reply and event"
  does not reach it. Whatever UTERM-054 settles for a caller's read scope needs the driver's access passed to that
  check.
- UTERM-062 — its risk on UTERM-006 M5 asks M5 to name a tab. The driver's `show` built on this grant names one too.
- UTERM-064 — a driver's path command names its target like any other command.
- UTERM-066 — "How long the grant lasts" waits on its verified driver identity before a driver's scope can be
  remembered.

## Summary

An exec driver can ask for a read scope while it runs. The user approves the scope for that run. The driver can then
name paths inside the scope, and learn about the files it shows, as a controller that holds `path-read` can.

## Motivation

An exec driver holds no path-reading power today. UTERM-015 gives a driver no opens, so a command that names a path is
refused for it. Every reply a driver receives is built with an empty read access, since its commands are submitted with
none. The image viewer's `shown` hard-codes the same empty access for drivers. A driver cannot ask the image viewer to
show a folder, and the viewer never tells it which image it shows.

UTERM-006 split the driver's `show` and stepping into M5, and the user declined to build a driver power inside
UTERM-006. UTERM-015 settles the power once for every applet. This proposal gives that power a driver form. The idea is
in `spec/ideas.md`, "Exec driver path-read power".

### What the scope guards

A driver is a local process uniterm starts with the user's own privileges. It can already open any file the user can,
as UTERM-015's rationale for the scope says: "A process uniterm starts, such as a shell or an exec driver, already holds
those grants directly, and the scope does not change that." So the scope does not limit what the driver process reads.

It limits what uniterm opens, shows, and reports on the driver's behalf. That matters when a party behind the driver has
no local file access, such as a driver whose argv is `ssh host program`. Without a scope, that party could learn which
files exist, and read content through what a viewer reports.

## Design Decisions (Settled)

### The same power as a controller's

Decision: a driver's read scope is UTERM-015's path-reading power, with no new rules for what it reads.

- The scope is UTERM-015's read scope type: a list of directories, within the same bounds. Protected locations inside a
  scope directory are excluded unless the scope names them.
- A path the driver names is walked off the main thread, opened without following a final symlink, and its opened
  descriptor's real path is checked against the scope.
- Errors for paths outside the scope do not tell "missing", "not a supported type", and "denied" apart. Inside the
  scope, failures keep their causes, as for a controller.
- The bound of 4 concurrent walks per connection holds for a driver's channel.
- Authority and the scope are asked again at delivery, so a grant that ends while a command waits leaves no read.

**Decided by:** user, 2026-11-26

Rationale: ADR-14 P8 makes path reading its own power, and UTERM-015 defined it so every caller shares one definition. A
second definition for drivers would let the two drift. The scope guards what uniterm does for the driver, per "What the
scope guards", not what the driver process can read.

### The driver asks at run time

Decision: after the hello, the driver sends a request frame that lists the directories it wants. The request waits in
the Pending Requests panel, as a driver's clipboard and command powers do. It is not part of the exec declaration, and a
layout saves no scope.

- The launch approval never grants the scope, and neither does a controller's host-launch grant that covered the
  launch.
- The panel row lists the directories and any protected locations they name, bounded with a count of the rest.
- The grant lives on the run's attachment.

**Decided by:** user, 2026-11-26

Rationale: a scope saved in the declaration could only ever be a request, since ADR-14 P9 lets a driver keep no
remembered approval. Saving it would change UTERM-004's layout schema and its "Saved layouts" rule for no gain in
authority. A request at run time reuses the per-run pattern UTERM-028 settled.

### How long the grant lasts

Decision: the panel offers Deny and Allow for This Run. Allow Once does not make the scope stand, as for a controller,
since one `show` of a folder reads many files. A remembered approval, "always trust this driver", is deferred until a
driver has a verified identity.

**Revisit:** when UTERM-066 gives exec drivers a verified identity

**Decided by:** user, 2026-11-26

Rationale: ADR-14 P9 lets only a verified version or identity keep a remembered approval. A driver is known only by the
path in its argv, and anything can replace the file at that path between runs. Approving each run approves the program
the user just watched start.

### When the grant ends

Decision: run end, Revoke, and closing the driver's pane end the grant at once.

- Queued reads stop, and their handles fail without reporting an effect undone, per ADR-11.
- A reply still pending that was built with the grant's access fails too. A `wait` at the driver's own pane never
  answers with a path after the grant ends.
- The driver keeps its own channel after a Revoke, as UTERM-028 settles.

**Decided by:** new-proposal, 2026-11-26

Rationale: ADR-14 P11. UTERM-015 M4's recheck at delivery already stops queued reads for a controller, and the same
recheck covers a driver. A controller's pending `wait` keeps the access it started with, because a controller's access
shrinks only when its run ends, which fails the wait. A driver's grant can end while its run goes on, so its pending
replies must fail with the grant.

### One read access for every reply and event

Decision: a driver's read access is built in one place, from its attachment, and every applet's replies and events to
that driver use it. A driver with no grant gets the empty access it gets today. Each applet's own redaction rules are
unchanged. Only the access they are given changes.

**Decided by:** user, 2026-11-26

Rationale: today a driver's replies get an empty access by default at the two places its commands are submitted, and
the image viewer's `shown` hard-codes one. Handing every applet the attachment's access once keeps one rule for
redaction. UTERM-006 M5 can then adopt it without its own plumbing. An applet whose rule ignores access, such as the
map's file pins, needs its own proposal to change that rule.

### The request frame lands in place at version 0

Decision: the request frame and its revocation frame land in place at exec protocol version 0, under UTERM-063. The
app's hello is unchanged, and there is no version offer.

- Old driver, new app: a driver that never sends the request runs as before, and gets the empty read access.
- New driver, old app: an app built before this proposal refuses the request frame by name, under UTERM-063 M2's strict
  decoder, before any effect.
- The frames carry a compatibility promise only once uniterm's maintainers declare the exec wire stable.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: this is UTERM-028's skew analysis for its command frames, and holds for the same reasons. A hello field
would change what every driver reads, which UTERM-063 leaves to version 1 or later.

### The read frames

Decision: the request is a frame whose reply waits for the user's answer. One pushed frame tells the driver of a
revocation.

- The driver sends `{"type":"request-read","id":n,"directories":[…]}`. The list follows UTERM-015's read scope bounds:
  at most 32 directories, each at most 1024 bytes.
- The reply is success, listing the granted directories, when the user allows the request. It is a structured error
  when the user denies it, the request is withdrawn, or the request is refused.
- Only a request that reaches the panel uses up the run's one request. One refused for its bounds, a malformed list, or
  a full panel may be sent again, fixed.
- The success reply is written before any command can read under the scope.
- On revocation, the app pushes `{"type":"read","state":"ended","reason":"revoked"}`. Run end closes the channel, so it
  needs no frame. A command refused after a revocation says the grant ended, not that the path is outside the scope.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: a reply that waits for the user's answer is how a driver's clipboard, layout, and command requests already
work. Without the pushed frame, a driver could not tell a revocation from a path outside its scope. Leaving the frames
to implementation would let an implementer pick a permanent contract.

### One request per run

Decision: a driver's request reaches the panel once per run. A later request is refused. A driver that needs another
directory ends its run and asks again in the next one.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: this matches UTERM-028's one declaration per run, and a controller's one declaration at start. Widening
mid-run would need a rule for the panel's Deny key, a bound on the growing union under ADR-14 P15, and a rule for
commands already waiting when the scope changes. A driver that knows its folders asks for them up front.

### The pane's badge shows a held scope

Decision: while a driver holds the read grant, the pane's control badge counts it, as it counts a driver with a
clipboard or browser grant. The badge's menu names the scope's directories, bounded with a count of the rest, and offers
Revoke.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: the badge is where the pane already shows a driver's grants and offers Revoke. M1 needs Revoke there anyway.
A grant display on the run strip would be a second place, and UTERM-048's inspector is not built.

### Relative paths resolve against the driver's starting folder

Decision: a relative path from a driver, in its request or in a command, resolves against the folder the driver was
started in, which its declaration names. A driver started in `~/Pictures` that names `./trip` means `~/Pictures/trip`.
The resolved path is what the scope check and the scoped open use, and what replies report.

**Decided by:** user, 2026-11-26

Rationale: a relative path means the driver's own starting folder, as it does for any program. The folder is part of
the driver's declaration, so it flows explicitly through the exec contract, not through hidden state.

## Design Decisions (Open)

None.

## Risks

- **Users read the panel as protecting files from the driver** — likelihood: high, impact: medium. A driver can read
  the user's files itself, so a Deny does not stop that. A user who believes otherwise may launch a driver they would
  not trust. Mitigation: the panel text says the grant governs what uniterm opens and reports for the driver.
- **A driver relays a remote party** — likelihood: low, impact: medium. With an approved scope, that party learns about
  files in it. Mitigation: the scope names directories, protected locations need naming, and the grant ends with the
  run.
- **Applets drift on how they redact for a driver** — likelihood: low, impact: medium. Mitigation: one read access per
  driver, built in one place, and the existing redaction tests run for a driver caller.
- **UTERM-066 may never cover some drivers** — likelihood: medium, impact: low. ADR-14 P9 says a shared interpreter's
  identity is insufficient, so a script driver may stay per-run after UTERM-066. Accepted: per-run approval still works
  for those drivers.
- **The request frame is a published wire addition** — likelihood: low, impact: low. Accepted: UTERM-063 keeps outside
  wires at version 0, and the only drivers are the user's own.

## Milestones

### M1: The driver read grant

**Status:** NOT STARTED

- A driver's request frame reaches the Pending Requests panel, which lists its directories and protected locations
- The panel row says the grant governs what uniterm opens and reports for the driver, not what the driver can read
- The panel offers Deny and Allow for This Run, with no Allow Once. Deny holds for the rest of the run
- Allow for This Run lets the driver's commands name paths in the scope, through UTERM-015's scoped open, in a test
  applet with a path argument
- The launch approval, and a controller's host-launch grant that covered the launch, never grant the scope
- A path outside the scope is refused with one error, whether it is missing, unsupported, or denied
- A relative path in a request or a command resolves against the driver's starting folder before the scope check, and
  replies report the resolved path
- Run end, Revoke, and pane close stop queued reads, and their handles fail. A driver keeps its channel after Revoke
- The driver's pane offers Revoke while the read grant stands, even when the driver holds no other grant
- The pane's control badge counts a driver that holds only the read grant, and its menu names the scope
- A `request-read` reply waits for the user's answer, and a success reply lists the granted directories
- A second request that reaches the panel in one run is refused. A request refused for its bounds, a malformed list, or
  a full panel may be sent again
- A Revoke pushes the `read` ended frame, and a later path command says the grant ended
- A second `request-read` sent while the first waits is refused at once, and never joins the first one's panel row
- A `request-read` after a Revoke in the same run is refused with the "needs a new run" text, and a request still
  waiting when Revoke lands never grants
- A denied read request stays denied for the run, and its denial offers no Ask Again
- A path command sent before the user answers is refused as having no grant, and no scoped read runs before the success
  reply is written
- An app built before this proposal refuses `request-read` by name, before any effect
- A driver holds at most 4 concurrent walks, counted per driver channel
- A saved layout holds no scope, and a restored pane's Run asks again
- The exec protocol version stays 0, and the exec wire documentation describes the request frame

### M2: Driver read access in replies and events

**Status:** NOT STARTED

- Replies to a driver's own-pane commands and its member commands carry the attachment's read access
- Applet events sent to a driver carry the attachment's read access
- A driver's scope directories are resolved off the main thread, as a controller's are
- A driver with no grant receives exactly what it receives today, in every applet
- A driver whose scope covers a pane's source receives what a controller with that scope receives, in the text viewer
- Ending the grant fails replies still pending that were built with it, and later replies and events carry the empty
  access
- After a Revoke, a `wait` on the driver's own image pane that started while the grant stood fails, though the
  driver's channel stays connected

## Decision Log

- 2026-11-26: Drafted from `spec/ideas.md`, "Exec driver path-read power", to unblock UTERM-006 M5. The user chose a
  request at run time over a scope saved in the declaration, Allow for This Run as the only answer that stands, and one
  read access for every reply and event. Per-applet adoption stays in each applet's proposal.
- 2026-11-26: Remembered approval for a driver is deferred to UTERM-066, verified identity for exec drivers. The user
  asked for that proposal after learning a driver has no verified identity, unlike a packaged controller.
- 2026-11-26: Critique pass 1, SOUND WITH CAVEATS. Added "What the scope guards" to Motivation, and rewrote the risks
  to match it. A driver reads the user's files itself, so the scope guards what uniterm does for it. Removed the risk
  that the program at the driver's path is not the expected one, since the launch approval owns that exposure. Added
  to "When the grant ends" that pending replies built with the grant fail with it. Added open questions on the request
  frame's contract and on relative paths. Added options and constraints to the other open questions, and corrected
  their facts. Corrected Impacts on UTERM-008, UTERM-040, UTERM-054, and UTERM-055. Routed checks to M1 and M2 for the
  session-only panel answer, Revoke on the pane, the walk bound per channel, wire documentation, and event access.
- 2026-11-26: Critique pass 2, a re-check, converged with no design-level defect. Corrected the Deny key's fact in
  "Asking again". Routed the panel text and a pending `wait` failing after Revoke to M1 and M2.
- 2026-11-26: The user kept the scope for drivers, after the critique showed it guards what uniterm does for a driver,
  not what the driver reads. The alternative was no scope, with path commands open to any file.

- 2026-11-26: Settled four open questions, on the user's instruction to keep going, using the critique's rankings and
  UTERM-028's frames as the pattern. The request frame lands in place at version 0. The frames are `request-read`, with
  a reply that waits for the user, and a pushed `read` ended frame on revocation. One request per run, with a resend
  after a refusal for bounds or malformed input. The pane's badge shows a held scope and offers Revoke. Turned down: a
  hello field, no frame at all, widening mid-run, and a grant display on the run strip. Left "Relative paths from a
  driver" open for the user, since CLAUDE.md asks that a choice about an attribute's explicit flow be the user's.
  Routed the frame, resend, revocation, and badge checks to M1. (autonomous)
- 2026-11-26: Re-check of those four decisions converged with no design-level defect. Routed four checks to M1: a
  second request while one waits, a request after a Revoke, no Ask Again after a Deny, and no read before the success
  reply.
- 2026-11-26: Settled "Relative paths from a driver", the user's choice. A relative path resolves against the folder
  the driver was started in. The user turned down refusing relative paths. Routed an M1 check.

- 2026-11-26: Accepted by the user.
- 2026-11-26: Scheduled as UTERM-065 M1-M2 in queue.md.

## References

- ADR-11: deferred replies never hide effects
- ADR-13: external wires stay compatible
- ADR-14: a controller controls what it opened, within authenticated identity and explicit scope
- `spec/ideas.md`, "Exec driver path-read power"
