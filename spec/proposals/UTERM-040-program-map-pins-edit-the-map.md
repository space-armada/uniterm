# UTERM-040: A Program's Map Pins Edit the Map as the User's Do

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-26

## Dependencies

- UTERM-008, for the map's pin commands and its command layers
- UTERM-016, for the editable document, Save, undo, and the unsaved-work prompt. M1 to M3 are built. M4 is not
  started, and this proposal drops it. See "Whether this proposal folds in UTERM-016 M4, or depends on it".
- UTERM-015, for the path-reading power

## Impacts

- UTERM-008 — "Where pins come from": the command-source bullets. Every command names a layer. A command cannot touch
  the file layer. `set-layer` replaces a whole layer. The default layer is shared by every caller. The per-layer cap, the
  32 KiB script bound on a layer, and Clear Program Pins. Superseded in part.
- UTERM-008 — the description section: the bullets that command layers ride in the undo-only part, show "From an
  earlier run" after a reopen, and count in the payload's `commandLayerCount` with a relaunch notice. Superseded in
  part.
- UTERM-008 — M3 and its As built: the layer store, the layer caps, the per-layer accents, the `pin-selected` event's
  layer field, and the "From an earlier run" callout. Superseded in part.
- UTERM-016 — M4. It becomes `DROPPED` and is replaced by UTERM-040 when this proposal is accepted.
- UTERM-016 — "Scripts may edit the file, and only the user saves", and the Impacts line on UTERM-008's "Where pins
  come from". Superseded in part when this proposal is accepted.
- UTERM-016 — M1 As built: a failed read takes the edit back and clears the undo stack. Superseded in part: a read
  failure reverts nothing.
- UTERM-016 — M1: the reader's byte bound, measured in M1, now also refuses the user's own edit that would pass it.
- UTERM-016 — M2 As built: the window in which an edit is refused while the previous edit's pins are read. Superseded
  in part: no edit waits on a read.

## Summary

A program's `add`, `remove`, `clear`, and `set-layer` edit the map's document, as the user's pin actions do. The edits
undo, mark the map unsaved, prompt at close, and are written by Save. Command layers retire. Authority gates which
programs may edit.

The commands move to map command schema 2.0. A new `pins` command lists pin addresses. Three things change for the
user's own edits. No edit waits on a read. An edit that would pass the map's measured byte bound is refused. While a
read refuses the document, the user's new edits and Save are refused until the document goes back to a readable map.

## Motivation

ADR-15 says a program's operation is the user's operation, carried out through the program. It behaves as the user's
does. Only authority stays apart. The user ruled on 2026-11-21 that this applies to a program's pins on the map.

Today the two differ in every way a user can see. A program's pins live in named command layers
(`Packages/UnitermKit/Sources/GeoData/CommandPins.swift`, `MapViewerApplet+Remote.swift`). A user's pins are edits to
the open GeoJSON document, from UTERM-016.

- The user's edit is one undo step. A program's command has no undo.
- The user's edit marks the map unsaved, and closing asks. A program's pins never mark it unsaved.
- Save writes the user's pins to the file. Save never writes a program's pins.
- A closed pane's program pins show "From an earlier run" after a reopen
  (`MapViewerApplet+Remote.swift:185`). They are gone at relaunch.
- A command cannot touch the file layer. The command refuses `source: file`
  (`MapViewerApplet+Remote.swift:81-86`). The user can edit only file pins.

A program's pins then look like a different kind of pin. They sit in a separate set the user can only clear in bulk.
ADR-15 names this pattern: a guard on one source that makes the same action mean two things.

UTERM-008 and UTERM-016 hold related text. UTERM-008 is implemented, so its text is frozen. UTERM-016 is accepted, and
its M4 is not started. The fold decision settles how this proposal and M4 fit.

## Design Decisions (Settled)

### A program's pin commands edit the document

Decision: `add`, `remove`, `clear`, and `set-layer` edit the map's document, through the path the user's pin actions use.

- Each command names the map tab it edits, as UTERM-062 M1 requires of every program command to a viewer, and edits
  that tab's document. Amended 2026-11-26; see Decision Log.
- Each command is undoable, as the user's edit is. A command is one undo step.
- A command marks the map unsaved. Closing a pane, a window, or the app asks Save, Don't Save, or Cancel, as UTERM-016
  "Unsaved work on close and quit" sets.
- Save writes a program's pins to the file, byte-patched as UTERM-016 "A save patches the file's bytes" sets.
- A program may edit the file's pins, and the user may edit a program's pins. After this change there is one set of
  pins.
- Command layers retire. The layer store, the undo-only layer snapshot, the "From an earlier run" mark, and Clear Program
  Pins go away. The user's Clear File Pins and Undo remain.
- Only the user saves. A program has no write command. Writing the file stays the user's Save. This is UTERM-016's rule
  and needs no new write power.

Rationale: a program's operation behaves as the user's, per ADR-15. The user's pin action is the same operation. An
action means one thing, whoever starts it. What it leaves behind is the same, so a program's work never goes missing at
the next launch because of who did it. Chosen by the user on 2026-11-21.

### Authority gates writing

Decision: whether a program may edit the document is decided before it edits, by authority, and an edit that is allowed
is not weakened.

Rationale: this is ADR-15's authority carve-out. UTERM-016 "Scripts may edit the file, and only the user saves" already
gates a script's edit on the path-reading power, since the commands and their replies reveal the file's pin IDs. The
shape of the gate is settled in "What power lets a program edit the document".

### Whether this proposal folds in UTERM-016 M4, or depends on it

Original question:

UTERM-016 M4 is accepted and not started. It adds a file-layer target to the command schema, gated by the path-reading
power, and a pin list that shows program layers read-only with a Clear action. This proposal also changes how a program
edits pins.

- Fold. This proposal takes over M4's script editing, and UTERM-016 is amended to point here. One design gives one edit
  path, one ID rule, and one gate. No program ever has two ways to edit pins. M4's third check has no layers left to show,
  so it goes. The cost is amending an accepted proposal on the strength of a design that is still open, and M4's checks
  move to this proposal's M1.
- Depend. M4 is built first as written. A program then has a file-layer target beside the command layers. This proposal
  retires the command layers after, and its commands move onto the file-layer target. UTERM-016 stays untouched, and M4
  ships on its own schedule. The cost is a second edit path built only to be removed, with two ID rules and two
  behaviors in between, and M4's read-only layer rows built only to be removed.

Decision: fold. This proposal takes over UTERM-016 M4's script editing. UTERM-016 stays untouched while this proposal
is a draft. At acceptance, UTERM-016 M4 becomes `DROPPED`, with a Decision Log entry and a `Replaced by: UTERM-040`
line, per `proposals.md` "Milestone Status". UTERM-016's "Scripts may edit the file, and only the user saves" is
marked "Superseded in part by UTERM-040" in the same step. M4's third check, read-only program layer rows with a Clear
action, is dropped with it. Program pins become ordinary document pins that UTERM-016 M3's pin list already lists.
Once M4 is dropped, every remaining UTERM-016 milestone is built, so UTERM-016 becomes `implemented` in the same step.
(autonomous)

Dropping M4 and its third check is a decision the user confirms at this review's gate. It is not marked decided.

Rationale: one edit path, one address rule, and one gate. Depending on M4 would publish a `source: file` target with
file-order IDs that this proposal then retires, and a published meaning must be kept. Amending UTERM-016 before this
design settles would point accepted text at open questions. Converged in 2 passes.

### What power lets a program edit the document

Original question:

Settled: authority gates writing. Open: which power.

- Option A: the path-reading power over the open file, as UTERM-016 M4 settled it. A map with no file, and a file outside
  the caller's scope, are then not editable by that caller. Today's pin commands need only pane control, so a driver
  that edits a map it started would now need a path grant.
- Option B: pane control alone, as today's commands need. A program with control of the pane edits the document. The
  commands and replies then reveal file pin IDs to a caller with no path grant. UTERM-015 "The path-reading power"
  says that a caller outside the scope gets no path or content detail from the source.
- Option C: pane control, and the path-reading power only when the pane holds a file. A pane with no file has no
  content to protect.

Decision: option C. A pin command needs pane control. When the pane shows a user's file, the caller must also pass
`ReadAccess.mayShow` for that file, the convention the text viewer already uses. A map with no file needs pane control
alone. The check runs at the effect, against the pane's file as it is then, so it follows the user's Save As, a
bookmark that moves the file, and Clear File Pins. A refusal names no path. (autonomous)

- Staging an unsaved edit in a pane is controlling it. Writing the file stays the user's Save, as UTERM-016 settled,
  so no permission's meaning changes and no version bumps.
- What the gate protects is which file the user opened and what it holds. An exec driver already holds the user's
  macOS file grants (UTERM-015), so the gate is not about file-system access.
- An exec driver holds no path-reading power today, since exec submissions carry no read access. So a driver may
  place pins only on a map with no file. Today a driver can place command-layer pins over a user's file. That stops.
  A way for a driver to hold the path-reading power is a separate addition, not taken here.
- A user's hand-placed pins on a map with no file are visible to a driver controlling it. UTERM-015 protects a
  user's file, not unsaved content.

Rationale: authority gates writing, per ADR-15's carve-out, and C reuses the gate UTERM-016 settled. Option A refuses
drivers where there is nothing to protect. Option B reveals a file's pin IDs to a caller with no grant, against
UTERM-015. Redacting replies field by field is the per-source guard ADR-15 rejects. A new permission kind protects no
failure C leaves open. Converged in 2 passes. The critic ranked a driver path-reading grant second, as an addition.

### Pin IDs

Original question:

A command pin has a caller-chosen ID, unique within its layer. `add` requires one and replaces an existing pin with it
whole, and `remove` takes one. A file pin's ID comes from file order, and a removal or a split renumbers the later pins
(UTERM-016 M2 As built). Candidates:

- Keep caller IDs as a property in the feature, such as `uniterm:id`. A command finds a pin by that property. A pin the
  user placed has none, and cannot be removed by a command.
- Use file-order IDs for every pin. A command's ID is then unstable across edits, and a program must read the IDs back
  after each edit.
- Give each pin a stable ID that the file stores. Every pin the user places also gets one.

Decision: option D. A pin's address is its stored `uniterm:id` when exactly one pin holds that value. Otherwise its
address is its file position, given in a separate argument together with the coordinate the caller expects. A
mismatch is refused, never applied to another pin. Positions reach only callers that pass the gate in "What power lets
a program edit the document". Where a program learns positions is settled with "The `pin-selected` event".
(autonomous, addition)

- A program's `add` writes the caller's ID as `uniterm:id`, as uniterm already writes `uniterm:accent` and
  `uniterm:glyph`. The user's own new pins get none.
- "Exactly one" is counted per pin. A MultiPoint whose feature carries `uniterm:id` gives its members no stored
  address, and they are addressed by position.
- A duplicated or missing ID leaves the pin addressable by position only.

Rationale: D is the only option under which a program can address every pin, including the user's and pins already in
the file, as the settled decision requires, without a stale address hitting another pin. Caller IDs alone cannot reach
pins already in the file. File-order IDs alone let a stale `remove` delete a different pin. Writing generated IDs into
every pin writes properties the user never edited, against UTERM-016's patch rule. Converged in 2 passes; the critic
proposed D, and completed it with the need for a source of positions.

### Wire compatibility for existing drivers

Original question:

A map's command schema is versioned, and an older driver must keep working, per UTERM-008 "Risks" and ADR-13. `add`,
`remove`, `clear`, and `set-layer` at schema 1.0 mean "act on a command layer". The new meaning acts on the document.
Candidates:

- Redefine them at 1.0. This breaks UTERM-008's rule that a version keeps its meaning.
- Publish the new meaning as schema 2.0, and keep 1.0 working. The map then keeps a layer store for 1.0 drivers, which
  contradicts retiring command layers.
- Publish 2.0, and refuse 1.0 commands with a structured error that says why. This is a change under ADR-13, which
  requires a proposal that names the direction that fails and the programs it breaks.
- Keep the command names at 1.0 and add the edits as new commands. Existing drivers are unchanged, and the old commands
  are retired later by their own proposal.

Decision: option C. The new meaning is map command schema 2.0, and a 1.0 command is refused before any effect,
with text that names 2.0 and why. A 1.0 `set-region` is refused too. UTERM-038 changed `set-region` at 1.0 to save
the region. It is refused anyway because 1.0 is unpublished and 2.0 replaces the whole schema. (autonomous)

- This rests on map schema 1.0 being unpublished. Published means merged to the mainline branch. Today the map's
  commands are not on the mainline. The failing direction, if 1.0 were published first, is a released 1.0 driver
  against this build: it would be refused. See Risks.
- Old driver, new app: a 1.0 driver is refused at the exec hello, and a 1.0 script call at dispatch, before any effect.
- New driver, old app: a 2.0 driver against a branch build at 1.0 is refused the same way. Against a mainline build the
  map takes no commands, so it is refused as an unsupported applet.
- The rule is UTERM-008's "A change an older driver cannot rely on adds a new version and never redefines an old one",
  and AppletKit's "A change in meaning or a removed command bumps the major". ADR-13 leaves an applet's command schema
  to its own rule, so it does not govern this.

Rationale: every refusal comes before any effect in both directions. Redefining 1.0 lets a driver's `clear` silently
act on the document. Keeping 1.0 alive needs the layer store the settled decision retires. Converged in 2 passes.

### A map with no file, and a file out of scope

Original question:

The user's pins on a map with no file are unsaved pins, and Save asks where to write them (UTERM-016 M2). Whether a
program's pins on such a map behave the same, and what a caller out of the file's scope sees, depends on the gate above.
Candidates:

- A program edits the unsaved document of a map with no file. Save asks where to write.
- A program edits only a map that shows a file.
- A caller outside the file's scope edits, and its replies carry no pin IDs or content from the file.

Decision: the first candidate, which follows from the gate. A program edits the unsaved document of a map with no
file, as the user's Add Pin does, and the user's Save asks where to write. A caller whose scope does not hold the
pane's file is refused before any effect, and the refusal names no path. A pane whose file failed to open still counts
as showing that file. (autonomous)

Rationale: "What power lets a program edit the document" already decides it. Editing only a map with a file would
leave an exec driver no map to pin on. Letting an out-of-scope caller edit reopens the redaction the gate rejected.
Converged in 1 pass.

### The payload's `commandLayerCount` and the relaunch notice

Original question:

The payload holds `commandLayerCount`, and a restore with a count above zero posts a notice that program layers were not
restored (`MapViewerDescription.swift:38-61`, `MapViewerApplet+Remote.swift:235-240`). ADR-06 gives the map its own
payload version. Candidates:

- Bump the payload version, drop the field, and drop the notice. An older build reads the new payload as unknown and
  keeps its bytes, per ADR-06.
- Keep reading the field and never write a count above zero. No bump, and an older build still reads the payload. The
  field stays as dead data.
- Bump the version, and keep a one-time notice for a layout that still holds a nonzero count from before this change.

Decision: keep payload version 1, and drop `commandLayerCount` from the reader and the writer. Drop the relaunch
notice. (autonomous)

- The mainline already writes the field at version 1, always as 0. Every reader since then decodes it as optional
  with a default of 0. So a payload without the field reads back with the same meaning on every build, and ADR-06
  needs no bump.
- A version 1 payload that still holds the field, from a branch build, decodes with the field ignored.
- Bumping the version would make every mainline build refuse the map pane and keep it only as bytes, for a change an
  older reader already round-trips.

Rationale: nothing dead stays in the format, and no build loses a map pane. Converged in 1 pass. The critic corrected
the question's premise: the field is on the mainline, not only on a branch.

### The `layer` and `source` arguments

Original question:

Every pin command takes `layer` and an optional `source` today (`MapViewerApplet+Remote.swift:30-53`, `:81-86`).
Layers retire, so these need a meaning. Candidates:

- Ignore both. A command is accepted and the argument has no effect. A driver written for layers keeps running, and
  its layers merge.
- Accept both and refuse any value but the default. A driver that names a layer gets a structured error. Nothing is
  silently merged.
- Remove both, as a new schema version. See "Wire compatibility".
- Keep `layer` as a free-text tag a pin carries in a property of the GeoJSON feature. `set-layer`, `clear`, and `remove`
  then act on pins with that tag.

The tag candidate also decides where a layer's default accent comes from.

Decision: drop `layer` and `source` at schema 2.0. Programs scope their pins through the stored `uniterm:id` they
already write, by an ID `prefix` that `clear` and `set-layer` take, matched only at a `/` boundary. A program chooses
IDs such as `trucks/7`. No property is stored beyond `uniterm:id`, and the settled address rule is unchanged.
(autonomous)

- A prefix never matches a pin with no stored `uniterm:id`, so it never reaches the user's own pins.
- What `clear` and `set-layer` reach with no prefix is settled in "What `clear` and `set-layer` act on". It must never
  reach a pin with no stored ID.
- A pin's ID, its prefix included, fits the existing 64-byte ID bound.

Rationale: it keeps a rerun's ability to replace its own pins, which UTERM-008 built `set-layer` for, with no second
stored format in the user's files. A stored tag would amend the settled address rule for no gain, since `trucks/7`
holds the same information as a tag and an ID. Dropping both with no scope would put every program in one ID space.
Keeping dead arguments serves no caller, since 1.0 is refused before arguments are checked. Converged in 2 passes.

### A command that arrives during an edit

Original question:

An edit is refused while the previous edit's pins are being read, since IDs come from file order (UTERM-016 M2 As
built). A command can arrive in that window. Candidates:

- Queue the command until the read ends, and reply after.
- Refuse it with `busy`, and the program retries.

Decision: no edit waits on a read, from any source. Every edit, the user's and a program's, patches the current
document bytes at once, and the patcher's coordinate check refuses an address that no longer matches. Reads coalesce:
at most one runs, and when it ends on bytes that changed since, one more read starts on the latest bytes. A failed
read reverts nothing. See "When a read refuses the edited bytes". While a file is opening, or reloading after a change
on disk, every edit is refused: the user's beeps, and a program's gets `refused` with text that says to retry.
(autonomous, addition)

- A user's edit whose pin no longer matches, from a list row or editor drawn before the latest read, beeps and redraws,
  as an edit in the window does today.
- Two pins at the same coordinate can be confused by a stale address. The settled address rule already accepts this
  for programs, and the user's editor has the same exposure.

Rationale: the window exists only because the user's UI named pins by IDs from the last read, and the patcher already
checks each address against the bytes. Removing the window for both sources gives one behavior per action, per ADR-15.
Keeping the window for the user while programs edit through it would lock the user out under a steady stream of
commands. Refusing programs during every read gives a driver one edit per read and a REPL script no way to retry.
Waiting in the applet breaks ADR-11, and waiting in the shared dispatcher would hold every pane in the window. This
changes UTERM-016 M2's window for the user's own edits, so it is an addition. Converged in 2 passes; the critic proposed
it as the complete option.

### What `clear` and `set-layer` act on

Original question:

`clear` empties a layer and `set-layer` replaces a layer's whole contents in one command. With no layers, either can
reach the user's own pins. Candidates:

- Both act on every pin in the document, including the user's. One undo step restores them.
- Both act on pins the program placed, found by the tag or ID property in the candidates above. The user's pins stay.
- Drop `set-layer` and `clear`. A program uses `remove` for each pin. A rerun script then cannot replace its earlier
  pins atomically, which UTERM-008 "Where pins come from" built `set-layer` to allow.

Also open: whether a `set-layer` is one undo step, and whether it is refused whole past a cap, as today.

Decision: `clear` and `set-layer` require a prefix, and act only on pins whose stored ID has it. Each is one
document replacement and one undo step. (autonomous)

- `set-layer` patches in place a pin whose ID it lists and the document already holds, as `add` does, so the pin's
  unknown properties and its place in the file stay. It removes the prefix's pins it no longer lists, and appends the
  new ones.
- A prefix set holding a pin the patcher cannot change, such as a pin in a GeometryCollection, refuses the whole
  command before any effect.
- A command that changes nothing registers no undo step and marks nothing unsaved, as the user's edit that changes
  nothing does.

Rationale: a program's bulk reach stays inside its own namespace, and a rerun still replaces its pins atomically, as
UTERM-008 built `set-layer` to do. Leaving out the prefix must not widen the reach to pins the user cannot tell apart
from their own, and the settled `layer` decision forbids reaching a pin with no stored ID. Dropping both commands gives
up atomic replace and costs one undo step per pin. Converged in 1 pass; the critic stated the in-place rule.

### The `pin-selected` event

Original question:

`pin-selected` names a command pin by layer and ID today. For a file pin it carries only a source marker, never the pin's
ID or any value from the file (`MapViewerApplet+Remote.swift:270-287`). Candidates:

- Every pin sends its ID, to a driver whose scope allows the document's pins. Other drivers get the marker.
- Every pin sends the marker only, and a program learns IDs from its own edits.
- Keep the event as it is while a pin carries a layer tag, and send the marker for a pin with none.

Decision: a new `pins` command lists pin addresses, and `pin-selected` carries the selected pin's address. Both
reach only a caller that passes the gate for the pane's file. (autonomous)

- `pins` replies with each pin's address, label, and coordinate. A `pins` call snapshots the document as it is on
  receipt. The listing is built off the main thread from that snapshot, and read page by page under a handle, so it
  always finishes. Each caller holds one live listing per pane, and a new `pins` call replaces it. Run end,
  revocation, and pane close free it. Each page read checks the gate again against the pane's current file. This
  follows the text viewer's remote handle table. A read may hold its reply until the listing is built, which ADR-11
  allows for a read.
- A `pins` call reflects every edit already replied to.
- `pin-selected` carries the pin's address: its stored ID when unique, else its position and coordinate. It is gated
  by the same `mayShow` check at emit time, against the pane's current file. A receiver that does not pass gets the
  event with no address.

Rationale: the settled address rule needs a source of positions, and no event reaches a script, which is the one
caller the gate lets edit a map that shows a file. Without a listing, no program could address the user's pins or pins
already in the file. A driver keeps learning which of its pins the user picked, as UTERM-008's clicks-go-to-the-program
relies on. A snapshot read page by page under a handle keeps a large document within one frame. An edit between
pages cannot skip or repeat a pin, since every page reads the same snapshot. `pins` is a new wire command at schema
2.0. Converged in 1 pass.

### The caps

Original question:

Commands are capped today at 624 pins per layer, 2,500 per pane, and 13 layers (`CommandPinLimits`). The per-layer cap
fits one exec frame, and a script's call stops at 32 KiB. Candidates:

- Drop the layer count and keep a per-pane cap of 2,500, with the per-command frame bound.
- Keep only the frame bound per command and use the file's existing bounds for the whole document (UTERM-016 M1).
- Keep all caps for commands, and leave the user's edits uncapped.

Decision: drop every layer cap. Keep a per-command bound sized to one exec frame, recomputed for the 2.0 command
shapes. Refuse any edit, from any source, whose result would pass the reader's byte bound, before any effect. The bound is
measured, not guessed: M1 measures the decoder's time and peak memory at several sizes and sets the bound from that.
32 MiB stays until the measurement replaces it.
The 10,000-point bound stays a display cut for both sources, and a program's reply carries the same past-limit notice
the user's edit posts. Undo and redo are never refused, since they restore a document the map already accepted.
(autonomous, addition)

Rationale: one behavior per action, per ADR-15. The byte bound is checked today only when a file is read from disk, so
an edited document can pass 32 MiB, save, and then fail to reopen. Refusing at the edit closes that at its cause and
gives ADR-08's burst check a defined largest document. Counting "program-written" pins has no meaning once there is one
set of pins, and today's layer caps count a store this proposal retires. This adds a refusal to the user's own edits
near 32 MiB, so it is an addition. Converged in 1 pass; the critic corrected the premise that the file's bounds already
applied to edits. The user
chose a measured bound at the review gate, since 32 MiB had no recorded basis. Some bound is needed because
`MKGeoJSONDecoder` builds the whole document in uniterm's own process and cannot stop part way.

### When a read refuses the edited bytes

Original question:

No edit waits on a read, and reads coalesce, so several replied edits can sit between two reads. Restoring the last
document a read accepted would retract every one of those replies and clear the undo stack. Raised by the coherence
review.

Decision: a read failure reverts nothing. The patcher is fuzzed against the shipped reader, and a read failure that
still happens is a fault the map contains. The map keeps a way back outside the undo stack. (autonomous, addition)

- The patcher joins `make fuzz` against the shipped reader. Its output that the reader refuses is a defect. The reader
  is MapKit and can change with macOS, so the fallback below stays a live, tested path.
- The patcher refuses a non-finite coordinate itself, before any effect.
- Save writes a snapshot only after a read accepted exactly those bytes. A Save during a read of those bytes awaits it
  off the main thread. If that read refuses the bytes, Save writes nothing.
- Save always finishes under a steady stream of edits. When no in-flight read is of Save's exact bytes, Save starts its
  own read of its snapshot off the main thread. It never waits on a read of other bytes.
- The map keeps the last bytes a read accepted, outside the undo stack. After a restore, that is the restored document
  if a read accepts it. If not, it is the file's bytes on disk, or an empty document for a map with no file.
- While a read refuses the document, a notice and a menu command offer "Go Back to the Last Readable Map". The action
  replaces the document with those bytes as one undo step, so the user can undo it.
- While the latest read has refused the document, every new edit is refused before any effect, for the user and for a
  program. Undo and redo stay allowed. A notice stays up until a read accepts the document. It names the Go Back
  action and does not say to undo back.
- No reply is retracted. An edit's reply stays true: the edit is in the document, and Save will not write it until a
  read accepts it.

Rationale: reverting after replies breaks ADR-11's promise that a reply states an effect that stands, and clears the
user's undo history. Validating each edit on the main thread before replying puts a full MapKit decode in every edit,
against ADR-08. Rolling back from the first bad edit drops good edits made after it. The undo stack cannot be the way
back. A burst between two reads can pass its 50 steps, and a restored document has no undo stack. So the map keeps the
last accepted bytes outside the stack. Go Back replaces the document with them as one undo step, so the user can undo
it. Refusing new edits in the failed state keeps the user from piling edits on a document no read accepts. Converged in
1 pass; the critic added the exact-bytes Save rule and the refusal in the failed state.

### The main-thread cost of patching

Original question:

Each edit patches the whole document on the main thread. With no layer caps, a burst of 32 commands can reach 32 MiB
in one dispatcher turn. Candidates:

- Measure first, and decide with the result.
- Move the patch off the main thread now.
- Bound the edits the dispatcher applies per turn now.

Decision: defer. Build nothing for this until a measurement exists. (autonomous)

**Revisit:** M1 measures a burst of edits on a document at the byte bound. If the longest main-thread gap stays under
30 ms, the bound UTERM-007 measured for the host, the deferral closes. If not, the patch moves off the main thread, or
the dispatcher bounds edits per turn, before M2.

Rationale: the cost is unmeasured, and either fix adds structure that a passing measurement makes needless. The
revisit hook puts the measurement in the first milestone, so the cost is known before the commands arrive.

## Design Decisions (Open)

None.

## Risks

- **A program's pins reach the user's file** — likelihood: medium, impact: medium. UTERM-008 kept program pins out of the
  layout because they can hold secrets, such as a host name or a location from a log. Save now writes them to a file the
  user chose. Mitigation: the layout file still never holds them, and nothing is written without the user's Save.
  Accepted by the user's ruling, since a user's pin is written the same way.
- **A command rewrites or removes the user's pins** — likelihood: low, impact: high. The prefix rules bound the reach.
  A prefix never reaches a pin with no stored ID. `clear` and `set-layer` require a prefix. An address-based `remove`
  or `add` can still reach a user's pin. Mitigation: one undo step restores it.
- **Existing drivers change behavior** — likelihood: low, impact: medium. Map schema 1.0 is unpublished on the
  mainline, so only in-repo tests and the user's branch-build scripts break. Mitigation: the wire compatibility
  decision names the direction that fails.
- **A pin from a program has no mark** — likelihood: medium, impact: low. After this change the user cannot tell which
  pins a program placed. `uniterm:id` is an invisible mark. Accepted: ADR-15 says the user can reproduce a program's
  work by hand.
- **`uniterm:id` becomes a stored format in users' files** — likelihood: high, impact: medium. Once a program's pin is
  saved, its `uniterm:id` sits in a file other tools read and edit, and later builds must honor it. Accepted: it follows
  the precedent of `uniterm:accent` and `uniterm:glyph`, and a missing or duplicated ID degrades to addressing by
  position, never to a wrong pin. (autonomous)
- **Map command schema 1.0 is published before this lands** — likelihood: medium, impact: high. The map's commands sit
  on a branch chunk that is ready to land. If they reach the mainline before this proposal's M2, schema 1.0 is
  published, and refusing it breaks every released 1.0 driver. A note in this proposal and in UTERM-008's landing is
  not available to landing tools, so a note cannot enforce the hold. Mitigation: a trigger. If UTERM-008 M3's commits
  land on the mainline before M2, the milestone that refuses 1.0, the wire decision reopens before any more work.
  (autonomous, addition)
- **A program leaves panes unsaved** — likelihood: medium, impact: low. A driver that places pins on a map it opened
  leaves the pane unsaved, so quitting asks Save, Don't Save, or Cancel for it, and Save opens a Save As sheet on a map
  with no file. Accepted: the user's own pins do the same, per ADR-15. (autonomous)
- **A program's commands push the user's undo steps off the stack** — likelihood: medium, impact: medium. Every edit
  shares the pane's 50-step undo stack, so 50 commands from a driver evict every undo step the user made before them.
  Each program edit also clears the user's redo stack, so a stream of commands loses redo. That weakens the mitigation
  that one undo step restores an edit. Accepted: the user's own 50 edits do the same, per ADR-15, and each command is
  still one step. (autonomous)
- **Saving a driver's map cuts the driver off** — likelihood: medium, impact: medium. Exec drivers hold no read access.
  Once the user saves a map a driver pinned on, the pane has a file. The driver's later commands are refused, and
  `pin-selected` loses its address. Drivers also lose placing pins over a user's file. Accepted: this is authority
  under ADR-15's carve-out. A path-reading grant for drivers is a separate addition. (autonomous)
- **Program-driven undo memory** — likelihood: medium, impact: medium. 50 undo steps, each a whole document, reach about
  1.6 GiB at 32 MiB. A program can fill them in seconds. The last bytes a read accepted add one more copy, up to
  32 MiB, and each live `pins` listing holds a snapshot that shares bytes with the document until an edit changes it.
  Accepted by reference to UTERM-016 M1's residual, since the user's own edits use the same stack. (autonomous)
- **ADR-15 is still proposed** — likelihood: low, impact: low. The rationale cites its text. The user's ruling on the
  first decision limits the exposure.

## Milestones

### M1: One edit model for every source

**Status:** NOT STARTED

- M1 measures the decoder's time and peak memory at several document sizes, records the numbers in the As built
  block, and sets the byte bound from them
- A user's edit whose result would pass the byte bound is refused before any effect, and undo and redo across that bound are
  never refused
- A pin's address is its stored `uniterm:id` when exactly one pin holds it, else its position with the expected
  coordinate, and the patcher refuses a mismatch
- `add` on an existing address patches the pin's fields and keeps its unknown properties byte for byte
- An omitted label, accent, or glyph on a patch keeps the pin's current value
- A patcher edit at a position does not write a `uniterm:id` onto a pin that has none, unless the edit carries a new ID
- `add` never makes a second holder of a stored ID
- Splitting a MultiPoint member never duplicates a stored `uniterm:id`
- Save writes only bytes a read accepted, and a Save during a read of those bytes awaits it off the main thread
- Save finishes under a steady stream of edits, reading its own snapshot when no in-flight read is of those bytes.
  Save's read may run beside the redraw read. Bytes it accepts become the last accepted bytes only when they are newer,
  and a refusal by Save's read is reported to the user and stops the write
- When Save writes a snapshot while the document has moved on, the saved bytes are that snapshot and the map stays
  unsaved
- A read failure reverts nothing, and while it stands every new edit by the user is refused, with undo and redo still
  allowed and a notice that names "Go Back to the Last Readable Map"
- "Go Back to the Last Readable Map" replaces the document with the last bytes a read accepted, as one undo step that
  undo reverses. After a restore, those bytes are the restored document if a read accepts it, else the file's bytes on
  disk, or an empty document for a map with no file. Go Back is allowed in the failed-read state while other edits are
  refused, and the bytes it restores count as accepted, so edits reopen without waiting on a refused read
- The patcher is in `make fuzz` against the shipped reader, and refuses a non-finite coordinate before any effect
- A reopened document the reader refuses shows the notice and keeps Save refused, and choosing Save at a close or quit
  prompt in that state cancels the close
- A user's edit that arrives while a read runs applies at once, and the map redraws from one read of the latest bytes
- A user's edit that arrives while a file opens or reloads is refused
- A burst of 32 edits in one dispatcher turn on a document at the byte bound keeps the longest main-thread gap under
  30 ms, the bound UTERM-007 measured for the host, and the measurement is recorded in the As built block

### M2: Schema 2.0

**Status:** NOT STARTED

- `add`, `remove`, `clear`, and `set-layer` edit the map's document, and each is one undo step
- A command marks the map unsaved, and closing asks Save, Don't Save, or Cancel
- Each delivered command is its own undo step, even when several are delivered in one main-thread turn
- A program's edit whose result would pass the byte bound is refused before any effect
- A program's edit in the failed-read state is refused before any effect, and undo and redo stay allowed
- An edit refused in the failed-read state gets an existing error code, named in the As built block, that differs from
  the code for an edit refused while a file opens, and a test proves the two differ. Its text names only "Go Back to
  the Last Readable Map". A new shared error code would be a design change and comes back to this proposal
- A program's edit that arrives while a read runs applies at once
- A program's edit that arrives while a file opens or reloads is refused
- Save writes a program's pins to the file, and a test proves the bytes outside the edit are unchanged
- A caller without the authority the gate requires is refused before any edit
- Command layers, the "From an earlier run" mark, Clear Program Pins, and the layer snapshot are gone
- A command after the user's Save As to a path outside the caller's scope is refused, and the refusal names no path
- A command's gate runs at the effect, including for any command that waited
- A command on a pane whose file failed to open requires `mayShow` on that file's path
- A 1.0 map command is refused before any effect, with text that names 2.0 and why
- An edit refused while a file opens gets `refused`, with text that says to retry, and a test proves it
- A version 1 payload holding `commandLayerCount` decodes, and the writer omits the field
- A `set-layer` whose pins include an ID outside its prefix is refused whole before any effect
- A prefix matches only at a `/` boundary, so `trucks/` never matches `trucks2/7`
- Prefix matching covers every pin in the document, not only the pins the map can show
- An empty prefix, or a bare `/`, is refused, and the check states whether a prefix matches an ID equal to it
- A prefix set holding a MultiPoint or GeometryCollection follows one stated rule, and `set-layer` never leaves a second
  holder of an ID it wrote
- A `clear` or `set-layer` is one document replacement and one undo step, and one that changes nothing leaves no undo
  step and no unsaved mark
- The per-command bound is recomputed for the 2.0 `set-layer` shape, with `prefix` added and `layer` removed
- A program's `add` past the 10,000-point display bound gets the past-limit notice in its reply

### M3: The listing

**Status:** NOT STARTED

M3 ships with M2, or before M2 lands on the mainline. The 2.0 shape of `pin-selected` must not change once it is
published.

- A listing always finishes under a stream of edits, each caller holds one live listing per pane, and each page read
  checks the gate again against the pane's current file
- In the failed-read state, `pins` answers from the current bytes or refuses with a stated kind, and never hangs
- Every page of one listing comes from the snapshot taken when `pins` was received, whatever edits land meanwhile
- A `pins` page fits the smallest reply bound of any caller transport, a script's 63 KiB, proven through a script
- Positions in `pins` and in `pin-selected` are the ones the patcher addresses, MultiPoint member indexes included
- `pins` lists and addresses pins past the 10,000-point display bound

Acceptance steps, not build checks. When this proposal is accepted, UTERM-016's script-editing section carries
"Superseded in part by UTERM-040", UTERM-016 M4 becomes `DROPPED` with a Decision Log entry and `Replaced by:
UTERM-040`, and UTERM-016 becomes `implemented`. UTERM-008 carries the markers for the replaced text.

## Decision Log

- 2026-11-21: Drafted after the user ruled that a program's pin commands edit the map's document as the user's pin
  actions do. They are undoable, make the map unsaved, prompt at close, and Save writes them. Command layers retire.
  Authority gates writing, as UTERM-016's path-reading rule for scripts does. The user left the mechanisms open.
- 2026-11-21: Whether to fold UTERM-016 M4 into this proposal or depend on it is open, as question 11. UTERM-016 is
  accepted and is not amended until the user decides.
- 2026-11-21: Review start: 1 milestone, 2 settled decisions, 4 risks, 11 open questions, no `**Live after:**` lines
  or row gates; no out-of-scope statements; as of the commit "File UTERM-039 and draft UTERM-040 to follow ADR-15".
  The user asked for an autonomous critique and review.
- 2026-11-21: Folded UTERM-016 M4 into this proposal, with UTERM-016 amended only at acceptance. (autonomous)
- 2026-11-21: A pin command needs pane control, plus `mayShow` on the pane's file when it shows one, checked at the
  effect. Exec drivers, which hold no path-reading power, may edit only a map with no file. (autonomous)
- 2026-11-21: A pin is addressed by its stored `uniterm:id` when unique, otherwise by file position with the expected
  coordinate. (autonomous, addition)
- 2026-11-21: The new meaning is map command schema 2.0, and 1.0 is refused before any effect. It rests on 1.0 being
  unpublished, held by a deployment dependency. (autonomous, addition)
- 2026-11-21: A program edits a map with no file as the user's Add Pin does. An out-of-scope caller is refused. Follows
  from the gate. (autonomous)
- 2026-11-21: `commandLayerCount` and its relaunch notice are dropped at payload version 1, since every reader decodes
  the field as optional. (autonomous)
- 2026-11-21: `layer` and `source` are dropped at schema 2.0. Programs scope pins by an ID prefix on `clear` and
  `set-layer`. (autonomous)
- 2026-11-21: No edit waits on a read, from any source. Reads coalesce, and edits are refused only while a file opens
  or reloads. Changes UTERM-016 M2's window for the user's own edits. (autonomous, addition)
- 2026-11-21: `clear` and `set-layer` require a prefix, act as one undo step, and `set-layer` patches listed pins in
  place. (autonomous)
- 2026-11-21: A new paged `pins` command lists addresses, and `pin-selected` carries the selected pin's address, both
  gated by `mayShow`. (autonomous)
- 2026-11-21: Layer caps go. A per-command frame bound stays, and any edit that would pass the 32 MiB byte bound is
  refused for every source. Undo and redo are never refused. (autonomous, addition)
- 2026-11-21: `pins` and the address in `pin-selected` are new public wire contracts. They serve the settled decision
  that a program may edit the file's pins, since a program cannot address the user's pins without them. (autonomous)
- 2026-11-21: The main-thread cost of patching is deferred. M1 measures a burst on a 32 MiB document, and the result
  decides whether the patch moves off the main thread or the dispatcher bounds edits per turn. (autonomous)
- 2026-11-21: Coherence pass. The fold now says UTERM-016 M4 becomes `DROPPED` and replaced by UTERM-040 at
  acceptance, and that the user confirms the drop at this review's gate. The Summary and Impacts name schema 2.0,
  `pins`, and the two changes to the user's own edits. The Risks are rated and extended. The `uniterm:id` address is
  tagged an addition. The 1.0 `set-region` wording is corrected. The bug on edits past 32 MiB is referenced. M1 is
  split into three milestones. (autonomous)
- 2026-11-21: Reopened "A command that arrives during an edit" on the coherence review's finding that a revert after
  replies retracts them. A read failure now reverts nothing: Save writes only bytes a read accepted, and new edits are
  refused while the read fails. (autonomous)
- 2026-11-21: A `pins` listing is a snapshot read by handle, so it always finishes. (autonomous)
- 2026-11-21: A read failure keeps a way back outside the undo stack. The map keeps the last bytes a read accepted.
  While a read refuses the document, "Go Back to the Last Readable Map" replaces the document with them as one undo
  step. The notice names it. The old claim that refusing edits keeps the last readable document on the undo stack was
  false. Save always finishes under a steady stream of edits by reading its own snapshot. It adds a user-visible failed
  state and a new action. (autonomous, addition)
- 2026-11-21: Design pass. The 1.0 hold trigger names M2. The patching cost threshold is a 30 ms longest main-thread
  gap, from UTERM-007. The `pin-selected` rationale describes the snapshot and handle design. The Summary names the
  third change to the user's edits. M1 loses its duplicate Save check, and its program halves move to M2. M2 gains the
  not-retryable error kind for the failed-read state. (autonomous)
- 2026-11-21: The proposal loop converged on its third pass. Its last implementation-level findings went to M1 and M2
  checks, and the risk review added the copy of the last readable bytes to the undo memory risk. (autonomous)
- 2026-11-21: Review gate, first call: the user kept dropping UTERM-016 M4, replaced by this proposal; kept that every
  edit applies at once, with the failed-read state and Go Back; and kept holding the map's command commits off the
  mainline until M2. The 32 MiB refusal is under discussion.
- 2026-11-21: Review gate: the user chose a measured byte bound over keeping 32 MiB as a guess. Edits past it are
  refused for every source.
- 2026-11-21: Review gate, second call: the user kept storing `uniterm:id` in users' files and adding the `pins`
  command. Nothing else changed.
- 2026-11-21: ADR candidate (cuts across the system): a contract a separately deployed program relies on keeps its
  meaning, for applet command schemas. Declined: it applies ADR-13's principle, and ADR-13 scopes applet schemas out
  on purpose.
- 2026-11-22: Scheduled as UTERM-040 M1-M3 in queue.md.
- 2026-11-26: From UTERM-062, which gives the map viewer tabs. A pin command names the tab it edits and edits that
  tab's document, so the question UTERM-062 raised of which tab a pin edit lands in has one answer. Undo stays per tab
  under UTERM-062 M5.

## References

- UTERM-008: the map viewer and its program commands
- UTERM-016: map pin editing, whose document, Save, and undo this proposal reuses
- UTERM-015: the path-reading power
- [ADR-06](../adr/ADR-06-layout-file-versioning-and-schema-ownership.md): the payload's own version
- [ADR-13](../adr/ADR-13-outside-wires-stay-compatible-across-versions.md): wire compatibility for drivers
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): authority
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): the decisions above rest on its rule that a program's
  operation is the user's, and on its authority carve-out
- [Bug: an edited map past 32 MiB saves but cannot reopen](../bugs/20261121-edited-map-past-size-bound-saves-but-cannot-reopen.md):
  the caps decision fixes it
