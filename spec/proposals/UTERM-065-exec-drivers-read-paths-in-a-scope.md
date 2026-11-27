# UTERM-065: Exec Drivers Read Paths in a Scope

**Status:** draft
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
UTERM-006. UTERM-015 settles the power once for every applet. This proposal gives that power a driver form. The idea is in
`spec/ideas.md`, "Exec driver path-read power".

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

## Design Decisions (Open)

### The request frame on the version-0 wire

UTERM-063 keeps the exec wire at version 0. Its strict decoders refuse an unknown frame. Today an unknown `type` is a
wire error, and the app ends the whole driver, after any effects of its earlier commands.

- A. Accept that. A driver that needs reads is ended by an older app at its first request. An old driver never sends
  the frame, and sees what it sees today. This matches UTERM-028's skew analysis for its command frames.
- B. The app's hello says whether it knows the request frame, and the driver skips it when not. This changes the hello
  every driver reads, against UTERM-063's "Version 1 or later may add hello fields" and UTERM-028's "The app's hello is
  unchanged". ADR-13 rejected optional features inside one version.
- C. No request frame. A driver's first path command asks for its folder, as a clipboard request asks on first use.
  This removes the wire change, but reopens "The driver asks at run time", a decision the user made.

### The request frame's contract

"The driver asks at run time" names a request frame but not its contract. UTERM-028 settled its frames as a decision,
since an implementer would otherwise pick a permanent contract.

- The frame's name and fields, and the bound on its directory list, which `ReadScope` caps at 32.
- Whether its reply waits for the user's answer, and its error codes, such as refused, bad argument, and busy.
- Whether a request refused for its bounds or malformed input may be resent, as UTERM-028 allows.
- How a driver learns its grant ended. Without a pushed frame it cannot tell a Revoke from a path outside its scope.
  UTERM-015's M4 review gives a run that knows its own grant its own refusal text.

### Relative paths from a driver

`ReadScope` and the scoped open take absolute paths only. A driver's declaration has a working directory, so a driver
may name `./trip`. CLAUDE.md asks that such an attribute flow explicitly, and that the choice be the user's.

- A. Paths must be absolute, in the request and in commands. A relative path is a bad argument, not an outside-scope
  error.
- B. Relative paths resolve against the declaration's directory, which the app already holds.

### Asking again to widen the scope

A driver may find mid-run that it needs another directory.

- A. One request per run, as UTERM-028 allows one declaration. A second is refused. A driver that needs a new folder
  restarts its run.
- B. A later request asks the user again, for the new directories only. ADR-14 P10 requires consent for a wider scope.
  Constraints: the panel's Deny key names the requester, the power, and anything that scopes it. When the read power's
  key leaves out the directories, a first Deny refuses every later request silently. When it includes them, each new
  set of directories asks again. A request the current scope covers needs no prompt. UTERM-015's M4 review makes a
  scope change refuse commands already waiting. ADR-14 P15 needs a bound on the union, which `ReadScope.union` does not have.
- C. A, plus a request refused for its bounds or for malformed input may be resent.

### Showing that a scope is held

The user should see that a running driver holds a scope, and have a way to revoke it. Today the pane offers Revoke for a
driver only while it holds a clipboard or browser grant or owns a group. The run strip says only that the driver runs.
The Pending Requests panel drops a row once it is answered. UTERM-048's pane inspector is accepted but not built.

- A. The pane's control badge counts the driver while it holds the grant, and its menu names the scope and offers
  Revoke.
- B. The run strip names the scope. The run strip shows no grants today, so this adds a grant display.
- C. Only UTERM-048's pane inspector shows it, once built.

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
- Run end, Revoke, and pane close stop queued reads, and their handles fail. A driver keeps its channel after Revoke
- The driver's pane offers Revoke while the read grant stands, even when the driver holds no other grant
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

## References

- ADR-11: deferred replies never hide effects
- ADR-13: outside wires stay compatible
- ADR-14: a controller controls what it opened, within authenticated identity and explicit scope
- `spec/ideas.md`, "Exec driver path-read power"
