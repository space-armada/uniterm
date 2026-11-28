# UTERM-010: Canvas Applet

**Status:** accepted
**Created:** 2026-10-31
**Updated:** 2026-11-27

## Dependencies

- UTERM-001
- UTERM-004
- UTERM-054, for the pane screenshot M1 checks the canvas adopts
- UTERM-051, for the off-main restore step that M3's sidecar read uses

## Summary

A canvas applet that programs draw on. A program sends drawing commands, and the canvas renders diagrams, shapes, and
text.

## Motivation

Programs sometimes want to show a diagram, not text. A canvas pane gives them a place to draw, like an HTML canvas.

Today an outside program can write an SVG file and a Markdown file that embeds it, then open the Markdown in the text
viewer, which reloads when the file changes. A Janet script has no such path. It has no rasterizer, sent Markdown shows
no images, and the image viewer does not decode SVG. No applet takes drawing commands, updates a drawing in place, or
reports clicks back to a program.

## Design Decisions (Settled)

### Programs draw, users view

The canvas is driven by a program. It is not a drawing tool for the user.

### How the canvas differs from the image and data viewers

Original question: the write-up has not yet worked out where canvas ends and the image and data viewers begin. Settle
this before the design.

Decision: the boundary is document versus scene. A viewer shows a document: a whole payload in a file format, such as
PNG, SVG, CSV, or JSON, decoded by a format decoder. That holds whether the user opened it or a program sent it. The
canvas shows a scene. A program builds the scene from drawing commands over the existing applet-command channel, which
Janet scripts and exec drivers both use. Only exec drivers receive applet events. A Janet script hears back through
canvas commands that wait, as in "Interaction". A document never goes to the canvas, and drawing commands never go to
a viewer, so every payload has one home.

Charts stay out of scope, as UTERM-009 recorded. A program that wants a chart draws it from primitives.

The drawing model that follows is a kept scene. See "Drawing model".

Rationale: every viewer already takes program-sent documents through `uniterm/send`, so a boundary drawn by where
content came from would give a sent PNG two homes. A canvas that also took chart specs would add a second contract with
no current caller. Retracting the canvas, or moving SVG into the image viewer instead, would leave Janet scripts with no
live diagram, no in-place updates, and no clicks.

**Decided by:** user, 2026-11-27

### Interaction

Original question: whether user clicks on the canvas go back to the program.

Decision: clicks go back to the program that controls the pane, for both kinds of program. A click carries its position
in the scene's own coordinates and the scene revision it hit. When the drawing model keeps shapes, it also carries the
id of the topmost shape the program marked clickable. Exec drivers receive clicks as events over the exec wire. Janet
scripts receive them through a canvas command that waits for the next clicks. ADR-11 lets that command hold its reply,
since it has no effect. Only a program that holds a grant over the pane gets clicks, per ADR-14. Clicks wait in a
bounded queue, and the program learns how many were dropped. Hover, drag, scroll, and keys are not delivered to the
program. Drag and scroll wheel stay with the user, who pans and zooms the view with them.

Rationale: forms and palette commands cannot point at a place in a diagram, so clicks are the only way a program learns
which part the user meant. Janet scripts have no applet-event channel, so an events-only design would leave out the
scripts the Motivation names. Hover, drag, scroll, and keys have no caller yet. Hover would also be a high-rate stream,
and keys raise ADR-04's reserved-key concerns.

**Decided by:** user, 2026-11-27

### Drawing model

Original question: immediate mode like an HTML canvas, retained mode like SVG, or whole SVG documents rendered by
WebKit.

Decision: the canvas keeps a scene of shapes. The program names each shape with an id it chooses, and places shapes
in named layers, the way programs place map pins. It adds, updates, and removes shapes by id, and it can replace a
whole layer. Adding an id that already exists is an error, and so is updating or removing an id the scene does not
hold. uniterm redraws, scales, and hit-tests the scene itself.

A program can stage changes across several commands and commit them. The user sees a commit as one change, so a scene
larger than one command never shows half-built. Each commit bumps the scene revision that clicks carry. Staged changes
that are never committed are discarded when the run ends, the grant is revoked, or the pane closes. Two bounds apply.
One caps the scene a commit would produce, and a separate one caps the changes staged and not yet committed. Each
refusal names its bound. Layers do not nest, and shapes have no groups.

Rationale: shape ids are what let a click name a shape and let a program edit in place. Commits give every revision a
complete scene, which the bounds decision needs, since a large scene takes several commands. A display list has no
ids, so every update is a clear and a full resend. Pixels blur under zoom and cannot be hit-tested. Whole SVG
documents are documents, and the boundary sends documents to viewers. A bitmap placed as a shape is out for the same
reason.

**Decided by:** user, 2026-11-27

### Payloads over a bound are refused, never cut

Every bound on what a program sends the canvas, such as the 32 KiB cap on one command's arguments, refuses a payload
that passes it. The program gets an error that says the payload is too large and names the bound. uniterm never cuts
the payload to fit, and never drops or ignores it. The working bound may sit a few bytes under a transport cap, so that
uniterm can tell an oversized payload from one that fits exactly. A program draws a large scene in several commands.

An exec driver's canvas command has its own argument bound, an eighth of the 1 MiB frame, as clipboard writes do. A
command over it is refused as that one request, by name. A line past the frame itself still ends the driver with the
exec wire's "line longer than" error, since the reader never learns that line's request id.

Amended 2026-11-27; see Decision Log.

**Decided by:** user, 2026-11-27

### Programs pass their own data, and JSON is only the wire

A program sends canvas commands through the existing applet-command channel. A Janet script passes Janet structs and
tables to `uniterm/send-command`, and gets Janet structs back, errors included. uniterm's bridge converts them to and
from JSON, so a script never writes JSON in a string. An exec driver writes the same JSON itself, since JSON lines are
its wire.

**Decided by:** user, 2026-11-27

### Shapes are typed, with geometry that fits each type

The vocabulary is abstract shapes, not a file format such as SVG. Each shape names its type and carries the geometry
that type needs, in the scene's coordinate space. A line has two points. A rectangle has an origin and a size. A circle has a center and a radius. A path is a list of segments. Text has an anchor point, its string, and
its font. A shared style covers stroke, fill, and whether the shape is clickable. "The shape vocabulary" settles the
exact list.

uniterm's scene model is the source of truth. A command updates the model. The pane draws the model, fitted to the view
with the user's pan and zoom. Any saved form, such as an SVG or PNG file, is generated from the model. Nothing edits an
SVG.

**Decided by:** user, 2026-11-27

### Diagram help: connectors in the canvas, and a Janet module on top

The vocabulary includes a connector. It names two shape ids instead of two points, and a marker at either end, such as
an arrowhead. uniterm draws it from one shape's outline to the other's, and redraws it when the program moves either
shape. Every kind of program gets connectors, since they live in the canvas. A click on a connector carries its id.

uniterm also ships a Janet module for diagrams. It creates shapes and returns their ids, using ids it makes itself, so
the program still chooses every id. It connects shapes by id, and it wraps staging and commit so one drawing call is
one revision. Its layered layout is in "Automatic layout".

**Decided by:** user, 2026-11-27

### The shape vocabulary

Original question: the exact shape types for M1, the geometry each one takes, and the style fields. Also how a program
declares the scene's extent, so that scene coordinates, keeping proportions on resize, and pan and zoom have a fixed
meaning.

Decision: M1 has lines, rectangles, circles, ellipses, paths, text, and connectors. A path is a list of move, line,
quadratic, cubic, and close segments. A connector may carry waypoints that its line bends through. A rectangle has an origin, a size, and an optional corner radius.
Rectangles, circles, and ellipses take an optional label: its text, font, alignment, padding, and whether the shape
fits itself to it. A fitted shape sizes itself to its label. The label draws inside the shape, exports as SVG text,
and is part of the shape for clicks and connectors. Lines, open paths, and connectors take an optional label too. It
sits at a fraction along the shape's length, the midpoint by default, with an offset to one side and an optional
background behind its text. It has no fit flag. On a connector with waypoints the fraction follows the bent route, so
the label moves with the edge. Clicking any label counts as clicking its shape. The style fields
are stroke color, stroke width, dash, fill, opacity, and clickable.

The program declares the scene's extent: a width and a height, with the origin at the top left and y growing down. The
view fits the extent to the pane and keeps its aspect ratio. An extent change is a staged change and lands with its
commit.

Shared command dispatch validates each shape by its type. The command schema gains a case for a value whose fields
depend on a `type` field, so a field that does not belong to a shape's type is refused, never ignored.

Z-order is insertion order within a layer, and layers draw in an order the scene states. The topmost clickable shape a
click hits is the last one drawn.

Colors follow "Background and theme colors", so a drawing stays visible on a light or a dark pane.

The canvas command schema crosses the exec wire to drivers built separately, so it follows ADR-13 at version 0. A
build refuses a shape type or field it does not know, by name. At version 0 a change lands in place. An older driver's
message is read with its old meaning or refused by name, never reinterpreted, so an older driver may stop working after
a change.

Amended 2026-11-27; see Decision Log.

Rationale: the set covers the shapes the proposal named, plus ellipses and curved paths for bent edges. The schema
case keeps shared dispatch the single validator, which the never-ignore rule needs. Staged extent changes keep a commit
whole. A defined z-order gives "topmost" a meaning. Transforms and gradients have no caller yet.

Amended 2026-11-27; see Decision Log.

**Decided by:** user, 2026-11-27

### Text measurement

Original question: a program cannot fit a box around a label without knowing how wide the text draws, and only uniterm
knows that.

Decision: both. The canvas answers a read that measures a list of strings, each with its font and an optional wrap
width. It replies at once with each string's width, height, and baseline in scene units. Shapes can also size
themselves to their label with a padding, and uniterm computes their size. A program can read a shape's computed bounds
while the shape is still staged, so it can size and place its nodes in one commit. Measuring and drawing use the same
font fallback.

Rationale: measurement gives sizes before any shape exists, which layout needs. Self-sizing lets labels refit when they
change, with no round trip.

**Decided by:** user, 2026-11-27

### Saving the canvas

Original question: whether a canvas can be saved beyond the pane screenshot UTERM-054 gives every pane.

Decision: the user can export the whole scene as SVG from the palette and a menu. uniterm generates the file from the
scene model. Every string a program sent, such as a label, is escaped, and shape ids stay out of the file. Fonts name a
generic fallback family. Programs can export the scene as SVG too. "How a program gets its export" settles the
mechanism. An exported file cannot be reopened as a live canvas.

Rationale: the screenshot holds only the visible view, in pixels. An SVG keeps the whole scene as vectors. A Janet
script cannot write its own file under its default sandbox, which denies file writes, so programs get the export too.

Amended 2026-11-27; see Decision Log.

**Decided by:** user, 2026-11-27

### The applet contract and what the description saves

Context from UTERM-001, which shipped the applet contract. ADR-05 and ADR-06 cover its lifecycle and its description
versioning. An ADR for the rest of the contract is a candidate in UTERM-001's Decision Log. This proposal may reshape
it, so it is not written yet. Every applet implements:

- A view the pane hosts, a title, and status bar segments.
- `start`, `focus`, and a palette update.
- `close`. uniterm sends this lifecycle event, and each applet owns its response, per ADR-05. uniterm keeps no closed
  applet alive. An applet that keeps work going after close owns its bound and a visible indicator.
- `isRunningSomething` and `runningLabels`. Closing a pane, a window, or the app asks first when an affected pane is
  running something, and the dialog names it.
- `describe()`, an inert description with a type and a per-type version. Undo and layout restore both rebuild the
  applet from it, in the same place. Undo is not a snapshot of running state. An applet that wants undo to bring back
  more saves it in its description. ADR-03 says restoring it never runs a program the user did not ask for. ADR-06
  says the applet owns its payload and its version. It upgrades its own older versions, and bumps the version on any
  change an older build cannot round-trip. A description this build cannot read is kept byte-for-byte.

Original question for the canvas: a description likely holds the drawing, or the commands that made it. When a
program drew it, restoring must not run that program again.

Decision: the committed scene lives in a sidecar file beside the layout, one per canvas, and the description names it.
The layout file stays small, and a layout save never encodes the scene. A relaunch brings the scene back from the
sidecar as inert data. Undo of a closed pane carries the committed scene in the description's in-memory undo part, as
the terminal and the map do, so it works in a second instance and never reopens a stale scene. Restoring never runs the program that drew it, per ADR-03. "When the sidecar is written
and removed" settles its timing.

Amended 2026-11-27; see Decision Log.

Rationale: keeping the scene for undo only would lose it after a relaunch, which defeats a restore. Putting the scene
in the layout file would grow every save and encode the scene on the main thread at each one, the cost UTERM-052 and
UTERM-059 remove for the browser and the terminal. The terminal already keeps shell scrollback in a store of its own.

**Decided by:** user, 2026-11-27

### When the sidecar is written and removed

Original question: when the sidecar is written, and when a closed pane's sidecar goes away.

Decision: a canvas writes its sidecar on the timing the layout saver uses. A write waits for a quiet second and is never
more than 10 seconds late. One write is in flight at a time, the newest scene wins, and each write is atomic. Pending
writes flush at quit, before the layout lock is released. A crash loses at most the last few seconds of drawing.

A sweep removes sidecars, at launch and again at quit after the final layout save. Only the instance that holds the
layout lock runs it. The sweep keeps every sidecar that the current layout or any kept-aside layout names. It deletes
nothing when any layout, or any canvas description in one, cannot be read.

A sidecar's format version follows its description's version, and a format change writes a new file name, so an older
build never overwrites a newer sidecar. A sidecar this build cannot read, whatever its description says, is kept
byte-for-byte and never overwritten. The pane shows a notice and takes no commits until a build that can read it runs.
A pane whose description this build cannot read is kept as bytes, per ADR-06 and ADR-18.

Amended 2026-11-27; see Decision Log.

Rationale: deleting a sidecar when undo can no longer reopen its pane needs a hook no applet has. It can also race the
debounced layout write. A sweep that counts only the current layout would delete sidecars that an older build cannot
see named, or that a set-aside layout still names. Writing at quit only would lose every scene since the last quit on a
crash.

**Decided by:** user, 2026-11-27

### Connectors whose shapes go away

Original question: what happens when a program removes a shape a connector names, or replaces the layer that holds it.

Decision: a commit is refused when the scene it would produce holds a connector that names a shape the scene lacks. The
error names the connector and the missing id. The check runs on the resulting scene, so removing a shape and its
connectors in one commit is fine, and the order of changes inside a commit is free. The Janet module's remove-node
stages the removal of the node's connectors in the same commit.

Shape ids are unique across the whole scene, not per layer. A connector may name shapes in any layer. A connector may
not name another connector, and the error names it.

Rationale: refusing keeps every committed connector pointing at real shapes, and nothing is removed behind a program's
back. The module gives scripts the cleanup for free. Exec drivers remove connectors themselves, guided by the error.
Edges usually sit in a layer below their nodes, so connectors cross layers. A connector between connectors has no
defined outline.

**Decided by:** user, 2026-11-27

### Automatic layout

Original question: whether the Janet diagram module also places nodes and routes edges on its own, given only nodes and
edges.

Decision: the module offers a layered layout. It places nodes in ranks, top to bottom or left to right, using measured
node sizes, and routes each edge through bend points. Connectors take optional waypoints for those bends, so a laid-out
edge still follows its nodes when the program moves them. The layout runs in the script, in Janet, not in uniterm.

The first check of the layout's milestone measures a 200-node, 300-edge layout's time and memory in the vendored Janet
build under the default sandbox. If it is too slow or too large, the layout waits, and the module ships without it.

Rationale: a Janet script cannot run a layout tool, since its sandbox denies subprocesses. Exec drivers can already run
one. Without waypoints, an edge that spans several ranks would cross the nodes between them.

**Decided by:** user, 2026-11-27

### A new run meets the scene of an earlier run

Original question: a relaunch or an undo brings a canvas back with its scene, and a driver that exits leaves its scene
in a live pane. A new run that adds an id the earlier scene holds would get an error.

Decision: the scene of a run that has ended stays visible, marked as from an earlier run. Its shapes are not clickable.
The next run's first commit replaces the whole scene, its extent and layer order included. Reads such as measuring text
or waiting for clicks change nothing. The same rule covers a relaunch, an undo, Run, and Restart.

A run is a grant. The scene has one owner: the grant whose commit made it. While the owner is live, a commit under any
other grant is refused with an error that names the owner, and clicks go to the owner. Once the owner has ended, a
commit under another grant is a new run's first commit. Two programs cannot draw on one canvas together.

Amended 2026-11-27; see Decision Log.

Rationale: one run owns the scene at a time, so ids from different runs never mix. The pane never goes blank before
the new run commits. A run's first command is often a read, so clearing on it would blank the pane early. Letting a run
inherit the scene would hand state silently from one program to the next.

**Decided by:** user, 2026-11-27

### Clearing the scene

Original question: whether programs and the user can clear a whole canvas.

Decision: the command set has a `clear` command. It stages the removal of every shape and layer, and returns the scene
to a fresh canvas's state. It lands with the next commit, so a clear and a redraw make one revision. Within a commit,
an add after a clear checks against the staged scene, and the scene bound counts the scene the commit produces.

The user has a Clear Canvas command in the palette and a menu, like the map's Clear Program Pins. It does what a
program's `clear` and commit do. The empty scene is saved through the usual sidecar write, never by deleting the file.
Undo brings the cleared scene back until the next commit. A live program's next command after a user's clear fails
with an error that says the user cleared the canvas, and its staged changes are discarded.

Rationale: an immediate clear would show a blank or half-built scene during a redraw. Deleting the sidecar would race
the sweep and give a false notice on relaunch. Undo past a later commit would wipe a live program's newer drawing.

**Decided by:** user, 2026-11-27

### Background and theme colors

Original question: whether the scene declares a background, styles name theme colors, or both.

Decision: any color in a style may be one of uniterm's theme tokens, such as `peach` or `text`, using the names the map
already takes. Token colors follow the pane's light or dark appearance and redraw when it changes, with no program
involved. Literal colors are allowed too. A scene that uses any literal color must declare a literal background, or
its commit is refused with an error that says so. The background is the theme's `base` unless the scene declares one.
When the scene declares a literal background, theme tokens resolve to the light or dark flavor that suits that
background's brightness, not the app's appearance.

Rationale: tokens keep a drawing readable in both appearances, as every other applet does. Literals let a program draw
exact colors, such as a color scale. Requiring a literal background with literal colors turns the invisible case, such
as black strokes on a dark pane, into an error.

**Decided by:** user, 2026-11-27

### How a program gets its export

Original question: a program's SVG export needs a way to reach the program.

Decision: the export command returns a handle, and the program reads the SVG in chunks, the way UTERM-054 returns a
program's pane capture. The export stays within that route's per-result cap, and needs no file-write power.

Rationale: a reply inline would refuse any scene whose SVG passes the reply cap. Writing to a folder would need a
sandbox power for scripts and a write scope exec drivers do not have.

**Decided by:** user, 2026-11-27

## Design Decisions (Open)

None.

## Risks

- **The drawing command set grows into a large contract** — likelihood: medium, impact: medium.
  Mitigation: the M1 set is fixed in "The shape vocabulary", and transforms and gradients wait for a caller. The command schema stays at
  version 0 until uniterm's maintainers declare it stable. Changes land in place, and an older message is read with its
  old meaning or refused, never reinterpreted.
- **The sidecar sweep deletes a live scene** — likelihood: low, impact: high. An automatic delete has no recovery, and a
  naming bug would empty a canvas the user wanted.
  Mitigation: the sweep keeps every sidecar any layout on disk names, deletes nothing when a layout cannot be read, and
  runs only in the instance that holds the layout lock. M5 checks each case.
- **The sidecar is a new stored format** — likelihood: medium, impact: medium. Builds read each other's sidecars across
  upgrades and downgrades.
  Mitigation: its version follows its description's version, and a build keeps what it cannot read byte-for-byte.
- **Canvas schema changes at version 0 break deployed drivers** — likelihood: medium, impact: low. The exec wire and
  ScriptWire both carry the schema, and a change lands in place.
  Accepted: the project keeps every external version at 0 until its maintainers declare it stable. An older message is
  refused by name, never reinterpreted.
- **The shared command-schema case changes dispatch for every applet** — likelihood: low, impact: medium.
  Mitigation: the case is additive, and every applet's existing command tests run against it in M1.
- **In-flight proposals shift under the canvas** — likelihood: medium, impact: low. UTERM-054's capture capability and
  UTERM-051's off-main restore step are accepted but not built.
  Mitigation: M1's screenshot check and M5's off-main read name them, and each waits on its proposal's milestone.
- **Sidecars pile up while a kept-aside layout is unreadable** — likelihood: low, impact: low. The sweep deletes
  nothing while any layout cannot be read, so closed canvases' sidecars stay until that layout ages out of the five
  kept-aside files.
  Accepted: disk use grows for a while, and nothing a layout might name is ever deleted.
- **The layered layout is too slow in Janet** — likelihood: medium, impact: low.
  Mitigation: M7's first check measures it, and the user decides whether the layout waits.

## Milestones

### M1: The scene, staging, and the command schema

**Status:** NOT STARTED

- Run and Restart give an exec driver a new grant, and a script's rerun gets a new grant. This is checked first
- A pane can run the canvas applet, and `open-pane` can start one
- A program draws lines, rectangles, circles, ellipses, paths, text, and connectors with end markers and waypoints on it
- Shared dispatch refuses a field that does not belong to a shape's type, by name, through the new schema case
- Shapes sit in named layers. A program adds, updates, and removes shapes by id, and replaces a whole layer. Adding an id
  the scene holds, or changing one it lacks, is an error
- Z-order is insertion order within a layer, and layers draw in the order the scene states
- Changes staged over several commands show at once on a commit, and the user never sees a half-built scene. An extent
  change lands with its commit
- The program declares the extent, and the drawing keeps its proportions when the pane resizes
- The scene and its description have a size bound. A program that draws past it gets an error that names the bound
- A command that passes its bound is refused as that one request, with an error that names the bound. For a Janet script
  the bound is 32 KiB of arguments. For an exec driver it is an eighth of the 1 MiB frame. Nothing is cut or dropped. A
  driver line past the frame ends the driver with the exec wire's "line longer than" error
- Staged changes past the staging bound are refused by name, and an in-place update of a scene near the scene bound
  commits
- A second live grant's commit is refused with an error naming the scene's owner, and clicks go to the owner
- The user pans and zooms the view by dragging and with the scroll wheel
- The pane screenshot from UTERM-054 captures a canvas pane, for the user and for a program with the capture power
- A commit whose resulting scene has a connector naming a missing shape is refused, and the error names both. Removing a
  shape and its connectors in one commit succeeds
- A connector that names another connector is refused by name, and a connector may join shapes in different layers
- A scene from an ended run shows marked as from an earlier run, is not clickable, and is replaced whole by the next
  run's first commit. A read from the new run changes nothing
- A staged `clear` and a redraw land as one revision. Clear Canvas empties the scene, undo restores it until the next
  commit, and a live program's next command fails with an error naming the user's clear
- Theme tokens on a declared literal background resolve by that background's brightness
- Token colors redraw when the appearance changes. A scene with a literal color and no literal background is refused
- A build refuses a shape type or field it does not know, by name

### M2: Clicks back to the program

**Status:** NOT STARTED

- A click on a clickable shape reaches an exec driver as an event, with its scene position, the revision, and the
  shape's id
- A Janet script receives the same click through the canvas command that waits for clicks
- Only a program holding a grant over the pane receives clicks
- Clicks wait in a bounded queue, and the program learns how many were dropped
- A drag or scroll pans and zooms, and sends no click

### M3: Text measurement and self-sizing

**Status:** NOT STARTED

- A program measures a list of strings, each with a font and an optional wrap width, and gets each one's width, height,
  and baseline in scene units in one reply
- A line, open path, or connector label sits at its fraction along the shape and follows a bent connector's route
- A rectangle, circle, or ellipse with a fitted label sizes itself to it, with its padding, and refits when the label
  changes
- A program reads a shape's computed bounds while the shape is still staged
- Measuring and drawing use the same font fallback

### M4: Export the scene as SVG

**Status:** NOT STARTED

- The user exports a canvas's whole scene as an SVG file from the palette and from a menu
- The exported file draws the same shapes, styles, z-order, and extent as the pane, opened in a browser
- A label that holds markup, such as `</text><script>`, comes out escaped, and the file runs no script
- The file holds no shape ids
- Text names its font with a generic fallback family
- A program's export returns the same SVG the user's export writes, read in chunks through a result handle
- Theme tokens resolve to the appearance in use at export, and the background is painted across the whole extent

### M5: Persist the scene in a sidecar

**Status:** NOT STARTED

- A canvas's committed scene comes back after a relaunch from its sidecar, and after an undo from memory, marked as from
  an earlier run, and restoring runs no program. Undo works in a second instance
- A crash loses at most the drawing from the last 10 seconds
- A sidecar that the current layout or a kept-aside layout names is never swept. When any layout cannot be read, the
  sweep deletes nothing
- An older build keeps a newer canvas and its sidecar byte-for-byte, and the newer build shows the scene again
- A sidecar this build cannot read, beside a description it can, is never overwritten, and the pane takes no commits
- A second instance writes no sidecars
- A description whose sidecar is missing restores an empty scene with a notice
- The sidecar is read and written off the main thread

### M6: The Janet diagram module

**Status:** NOT STARTED

- A script creates shapes through the module and gets their ids back
- A script connects two shapes by id with an arrowhead, and the edge follows when a shape moves
- Removing a node through the module removes its connectors in the same commit
- One module drawing call is one committed revision
- Ids the module makes never collide with ids a script writes by hand
- Re-evaluating a drawing in the REPL, which keeps one grant, redraws through the module without an id error

### M7: Layered layout

**Status:** NOT STARTED

- A 200-node, 300-edge layered layout runs in the vendored Janet build under the default sandbox, with its time and
  peak memory recorded in the As built block. When they are too high, the user decides whether the layout waits
- The module lays out a graph top to bottom and left to right on measured node sizes
- An edge that spans several ranks bends through waypoints and crosses no node between them

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-11-01: Added "The applet contract" with context from UTERM-001's implementation.
- 2026-11-27: The user retired the `detach` and `reattach` lifecycle events, and ADR-05 is amended to match. "The applet
  contract" said "`detach`, `reattach`, and `close`. uniterm sends these lifecycle events, and each applet owns its
  response, per ADR-05. On detach an applet pauses audio, video, and alerts at once." It now lists `close` alone.
- 2026-11-27: Review start: 1 milestone, 1 settled decision, 1 risk, no `**Live after:**` lines or row gates; no
  out-of-scope statements. At commit "Retire the applet detach and reattach events in ADR-05 and proposals". The user
  asked to settle the scoping questions first.
- 2026-11-27: Premise check: the problem exists in part. An outside program can show a live SVG through a Markdown file
  in the text viewer. Janet scripts have no diagram path, and no applet takes drawing commands or reports clicks.
- 2026-11-27: The Motivation said the canvas "is also a building block for the presentation example in UTERM-004." The
  presentation became UTERM-025, which shows slides in the text viewer, so the clause was dropped. The Motivation now
  records what programs can show today.
- 2026-11-27: Settled the boundary as document versus scene. Viewers show documents, sent or opened, and the canvas
  shows scenes built from drawing commands. Charts stay out of scope. Weighed: a boundary by where content came from, a
  canvas that also takes chart specs, SVG in the image viewer instead, and retracting the canvas.
- 2026-11-27: Added an M1 check that the scene and its description have a size bound.
- 2026-11-27: Settled interaction. Clicks go back to the controlling program as exec events, or through a waiting
  canvas command for Janet scripts, with a bounded queue. Weighed: exec drivers only; clicks plus hover, drag, scroll,
  and keys; and view only.
- 2026-11-27: The user corrected the boundary decision's wording. It said drawing commands come "over the existing
  applet-command and event channels that Janet scripts and exec drivers already use." Janet scripts have no applet-event
  channel, so it now names the command channel alone and points to the waiting commands in "Interaction".
- 2026-11-27: Settled the drawing model: a kept scene of program-named shapes in named layers, with staged changes
  shown on commit. Weighed: a kept scene without commits, a display list, and pixels only. Whole SVG documents and
  bitmap shapes fall outside the boundary decision. The M1 check on wire caps now names each wire's cap, since the exec
  wire caps a 1 MiB frame, not 32 KiB of arguments.
- 2026-11-27: The user settled three points from a discussion. Programs pass their own data and JSON is only the wire.
  Shapes are typed, with geometry per type, and the scene model is the source of truth for display and any saved form.
- 2026-11-27 (addition): The user chose connectors in the canvas vocabulary, plus a Janet diagram module that makes
  ids, connects shapes, and wraps commits. The module is a new component.
- 2026-11-27: Replaced the open question "Command format" with "The shape vocabulary", "Text measurement", "Automatic
  layout", and "Saving the canvas". It said "The wire format for drawing commands, and whether it reuses the UTERM-004
  exec format." The wire is now settled as the existing applet-command channel.
- 2026-11-27: The risk's mitigation said "version the command set." That conflicts with the project rule that every
  external version stays at 0 until the maintainers declare it stable, so it now says the schema stays at 0 and changes
  land in place. Added an M1 check that the canvas adopts UTERM-054's pane screenshot, which is optional per applet.
- 2026-11-27: Settled the shape vocabulary: the full M1 set, a declared extent staged with commits, validation by shape
  type through a new command-schema case, a stated z-order, and a background or theme colors. Weighed: the set without
  those fixes, a smaller set without ellipses and paths, and the set with transforms and gradients.
- 2026-11-27: Settled text measurement: a read that measures a list of strings, plus self-sizing shapes whose bounds
  can be read while staged. Weighed: the read alone, self-sizing alone, and no measurement.
- 2026-11-27 (addition): Settled saving: the user exports the scene as SVG, generated from the model, with program
  strings escaped. Weighed: the screenshot only, SVG plus a full-scene PNG, and export for programs too. Added an SVG export milestone.
- 2026-11-27: Added the open question "Background or theme colors", the choice the vocabulary decision left open.
- 2026-11-27: Settled what the description saves: the committed scene lives in a sidecar file beside the layout, and
  the description names it. The user rejected undo-only, since it loses the scene after a relaunch. Weighed: undo-only,
  the scene in the layout file, the layout file at quit only, and keeping the scene on the user's request. Added the
  open question "When the sidecar is written and removed".
- 2026-11-27: Settled the sidecar's timing and removal: debounced like the layout saver, flushed at quit, removed by a
  sweep that counts every layout on disk and deletes nothing when one cannot be read. Weighed: each commit with removal
  at close, at quit only, and never removed. Added a sidecar milestone.
- 2026-11-27: Settled connectors whose shapes go away: the commit is refused, and the Janet module's remove-node cleans
  up. Ids are unique across the scene, connectors cross layers, and a connector cannot name a connector. Weighed:
  refusal without module cleanup, silent removal, and a connector that draws nothing.
- 2026-11-27 (addition): Settled automatic layout: the Janet module offers a layered layout with connector waypoints,
  gated on a first-check measurement. Weighed: straight edges only, not now, and layout inside uniterm. The vocabulary
  decision gained connector waypoints; it said "A path is a list of move, line, quadratic, cubic, and close segments."
  with no waypoints. The diagram-help decision's last sentence said "Whether the module also lays diagrams out
  automatically is an open question." Added milestones for the module and the layout.
- 2026-11-27: Corrected the open rerun question. It said the map replaces a layer on a source's first write; the map's
  `add` replaces only the pin with the same id.
- 2026-11-27: Settled the rerun question: an ended run's scene stays marked and unclickable until the next run's
  first commit replaces it whole, with runs told apart by grant. Weighed: inherit with a module clear, clear on the
  first command, and the add error standing.
- 2026-11-27: Settled clearing: a staged `clear` command, and a user Clear Canvas that acts as a clear and commit, saves
  the empty scene normally, and can be undone until the next commit. Weighed: no clear and an immediate clear for
  programs, and no command or an earlier-run-only command for the user.
- 2026-11-27: Settled colors: theme tokens anywhere, literal colors allowed when the scene declares a literal
  background, and the theme's base by default. Weighed: tokens only, tokens and literals with no rule, and one literal
  background. The vocabulary decision's colors sentence now points here; it said "The scene declares a background, or
  styles can name theme colors, so a drawing stays visible on a light or a dark pane."
- 2026-11-27: Coherence review. Reorganized the milestones into seven, so every settled decision has one that builds
  it: the scene and schema, clicks, measurement, export, the sidecar, the module, and the layout. Measurement now comes
  before the module and the layout. Fixed stale text: the boundary and the description decisions still called the
  drawing model and the sidecar timing open, the typed-shapes decision gave rectangles a second form that the vocabulary
  dropped, the risk listed only five primitives, and M1 left out ellipses and connectors. Added UTERM-054 and UTERM-051
  to Dependencies.
- 2026-11-27 (addition): Two settled mechanisms reach outside the canvas, and the review tags them. The command-schema
  case keyed on `type` changes shared dispatch for every applet. The sidecar sweep needs a host hook at launch and at
  quit, since applets have only a per-pane `willQuit`.
- 2026-11-27: The user chose one owner per scene. The rerun decision said "While two grants are live on one pane,
  neither replaces the other's shapes, and the add error stands between them." It broke once one grant exited.
- 2026-11-27: The user chose a canvas bound for exec drivers at an eighth of the frame. The bounds decision now says a
  line past the frame still ends the driver, since the exec reader cannot learn its request id. The M1 check said a
  driver past the 1 MiB frame "gets an error it can act on, not only a closed connection."
- 2026-11-27: The user chose two size bounds, one for the produced scene and one for staged changes. The drawing model
  said "Staged bytes count against the scene's size bound." The clearing decision said "the size bound counts the scene
  the commit produces."
- 2026-11-27: The user chose a label field on rectangles, circles, and ellipses for self-sizing. The vocabulary had no
  label or padding field.
- 2026-11-27: The user chose to keep an unreadable sidecar and leave its pane inert, and a format change writes a new
  file name. The sidecar-timing decision said "A sidecar this build cannot read therefore always comes with a
  description it cannot read." Separate write timers break that.
- 2026-11-27: The user chose undo from memory. The sidecar decision said "Undo and a relaunch both bring the scene back
  from the sidecar as inert data."
- 2026-11-27: The user reworded the version-0 promise. The vocabulary decision said "An older driver keeps working with
  a newer canvas."
- 2026-11-27: The user extended labels to lines, open paths, and connectors, placed along the shape's length.
- 2026-11-27: The user chose to resolve theme tokens by a declared literal background's brightness.
- 2026-11-27: The user accepted the risk that sidecars pile up while a kept-aside layout is unreadable.
- 2026-11-27 (addition): A reason behind SVG export proved false: "A program already holds every shape it sent, so it
  can write its own file." Janet scripts cannot write files under their default sandbox. The user chose to give programs
  the export too. It said "Programs get no export command." Added the open question "How a program gets its export".
- 2026-11-27: The user chose a result handle for a program's export, read in chunks as UTERM-054's captures are.
  Weighed: inline in the reply, and a write into a granted folder.
- 2026-11-27: Risk review. Added risks for the sweep, the sidecar format, schema changes at version 0, the shared
  schema case, in-flight proposals, and the layout's speed.
- 2026-11-27: The user said drag and scroll wheel pan and zoom the canvas view. Added that to the interaction decision
  and an M1 check.
- 2026-11-27: The user set the rule for bounds: a payload over a bound is refused with an error that names it, and is
  never cut or ignored. Added as a settled decision and an M1 check.
- 2026-11-27: Review gate: the user accepted the proposal. No decision earns an ADR.

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, APPLET-6
