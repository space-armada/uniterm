# UTERM-025: Presentation Controller

**Status:** accepted
**Created:** 2026-11-15
**Updated:** 2026-11-20

## Dependencies

- UTERM-024, a required prerequisite: Next Slide, Previous Slide, and Stop Presentation, with the steps bound to the
  arrow keys, Page Up and Page Down, and Space
- UTERM-030, a required prerequisite: slide text that fills the pane, and slide images
- UTERM-032, a required prerequisite: the deck as an argument, its text handed to the presenter, and its folder granted
- UTERM-015 M4, a required prerequisite through UTERM-030 and UTERM-032: the path-reading power
- UTERM-003, for `uniterm run` and the Janet module
- UTERM-004, for controller runs, layout requests, groups, and remote control of the pane it opens
- UTERM-007, for the text viewer that shows the slides
- UTERM-021, for the `declare-permissions` form

## Impacts

- UTERM-026 — "Speaker notes" and "A second window": the presenter view and its notes build on this controller's deck
  format and commands. A second layout anchored at the starting terminal is refused once the user disconnects it, per
  "How the starting terminal joins the layout".
- UTERM-029 — "Stepping" and "Deck format rules": PDF and image-folder inputs become slides of this controller's
  Markdown body, and Go to Slide, First Slide, and Last Slide join its commands. A deck may name a PDF page as
  `![](talk.pdf#page=3)`. That reference uses the standard RFC 8118 form, so it adds no deck format marker.
- UTERM-031 — retracted. The risk "Stepping needs focus in the slide pane" is accepted on the user clicking the slide
  pane, and nothing waits on UTERM-031.
- UTERM-033 — "Summary": after a relaunch, running the presenter again reuses the restored slide pane. Not required.

## Summary

A presentation controller shows a Markdown deck, one slide at a time, in a text viewer pane beside the terminal that
started it. While the slide pane has focus, the user steps forward and back with the arrow keys, Page Up and Page Down,
Space, a clicker, or the palette. It is a controller, not an applet.

Everything here is on the hot path. Speaker notes, pane zoom, and the presenter view are UTERM-026. Other deck sources
and Go to Slide are UTERM-029.

## Motivation

Presenting from a terminal app is a real workflow: a talk about a tool, with the tool live in the next pane. Today that
means a separate presentation app and switching windows mid-talk.

uniterm already has the pieces to show content. The text viewer renders Markdown, and a controller can lay out panes
and command them. A presenter built from those pieces needs no new applet. It also proves the controller model on
something people use, rather than on test fixtures. And it gives anyone writing a controller a working starting point.
The repo has no sample controller today, and no `.janet` file outside the test fixtures.

`spec/ideas.md` "Sample presentation controller" records the starting survey.

## Design Decisions (Settled)

### A controller, not an applet

Decision: the presenter is a controller that drives existing applets. It adds no applet type.

Rationale: the applets already show the content. What a presenter adds is sequence and input, which is controller work.
Any gap it finds belongs to the controller model, where every other controller gains from the fix. A slide mode built
into the viewer would need fewer prerequisites, but would prove nothing about controllers.

### A Markdown deck

Decision: the deck is one Markdown file. Slides may hold headings, lists, code, tables, and images.

Rationale: Markdown is the one deck source the text viewer shows today. PDF, image, and HTML decks are UTERM-029.

### Slides only, beside the terminal

Decision: the presenter shows slides in one pane, beside the terminal that started it, in a normal window. Speaker notes
and a slide that fills the screen are UTERM-026.

Rationale: in one window the audience sees every pane, so a notes pane would show them the notes. A slide beside the
terminal suits a live demo, and the user chose it as enough for the hot path.

### How it starts

Decision: the user starts the presenter with the deck as an argument: `uniterm run presenter.janet deck.md`. Under
UTERM-032, uniterm hands the presenter the deck's text and, after the user approves, grants the deck's folder for slide
images. The presenter holds no file access of its own. It starts only through `uniterm run`, not from a REPL, since a
REPL takes no declarations.

Rationale: a deck is a file argument, the way any command takes one. The user chose the least access that works. Images
load from the granted folder through UTERM-030.

### The deck stays in the user's files

Decision: the presenter writes no copy of the deck to disk. The last slide's text stays in the pane's undo memory for
the rest of the launch, as any inline content does. Restoring a layout that held a presentation restores
the pane inert, per ADR-03 and UTERM-004.

Rationale: the deck is the user's document. A copy would go stale when the user edits it, and would hold content the
user did not choose to store. `show-markdown` carries each slide without writing it to disk, unlike `uniterm/send`.

### An example script

Decision: the presenter is a declared Janet file in the repo's examples. It is not bundled in the app.

Rationale: it uses only the declared-file format, so it needs no package-format entries for commands or the input file.
The user chose this. Bundling it, with signing, updates, discovery, and a versioned deck format, is a later decision.

### Stepping

Decision: Next Slide and Previous Slide are the presenter's commands, declared through UTERM-024. Right Arrow, Down
Arrow, Page Down, and Space step forward. Left Arrow, Up Arrow, and Page Up step back. Each command is also in the palette.
Stepping past either end leaves the slide in place and posts a status message. Stop Presentation joins them, per "How
it ends". Amended 2026-11-16; see Decision Log.

Rationale: these are the keys people step slides with, as in Keynote and PowerPoint, and the keys clickers send. A
press past the end is a common slip mid-talk, so the slide stays up rather than blanking.

### Deck format rules

Original question: how slides split, since a `---` line collides with a setext heading, where a line of text is
followed by `---`, and with `---` inside a fenced code block. And how a slide references images, relative to the deck
file.

Decision, splitting: a line that is exactly `---`, with no indent and optional trailing spaces, ends a slide when the
line before it is blank or it is the deck's first line, and it lies outside a fenced code block and outside an HTML
block that runs past blank lines. (autonomous)

- A `---` directly under a line of text stays a setext heading, as CommonMark reads it.
- Fences are tracked by their opening character and length, as CommonMark closes them.
- The HTML blocks that run past a blank line are `<pre>`, `<script>`, `<style>`, and `<textarea>` blocks, comments,
  processing instructions, declarations, and CDATA. A `---` inside one never splits it. Every other HTML block ends at
  the blank line the rule requires.
- A slide that holds only whitespace is dropped. A deck that starts with `---`, or holds two separators in a row, gets
  no blank slide.
- Front matter is not special. A deck that starts with a YAML block shows it as text.

Rationale: every split the rule makes is a thematic break where markdown-it, the viewer's renderer, would draw one. So
the same file reads the same way opened as a document, with a rule between slides. A `---` is the separator that Marp,
Slidev, and reveal.js decks already use. The rule needs only a line scanner in Janet, not a copy of markdown-it's block
parser. An HTML comment holding notes with a blank line and a `---` inside it never splits, which keeps that candidate
open for UTERM-026's speaker notes. Reproducing every CommonMark thematic break, `***` and indented forms included,
would need a Janet copy of the block parser, and any place the copy differs would split wrongly. A heading boundary
cannot hold an image-only slide, and splits a title slide with a subtitle in two. An HTML comment separator shows no
break between slides when the deck is opened as a document. Converged in 1 pass.

Decision, images: a slide's relative image paths resolve against the deck file's canonical folder. The presenter sends
every slide with `(uniterm/input-folder)` as its base folder. A link or image reference definition anywhere in the deck
applies to every slide. With each slide, the presenter sends the deck's definitions whose labels the slide may name.
(autonomous)

- A definition is a line indented at most three spaces, `[label]: destination`, with an optional title on the same
  line. It lies outside a fence and an HTML block, and does not continue a paragraph. A slide's own definition of the
  same label wins, since CommonMark takes the first and the slide's text comes first.
- A slide may name a label when the label's lowercased, whitespace-collapsed form appears inside brackets in the
  slide. A label with non-ASCII characters is always sent. The filter errs toward sending: an extra definition renders
  nothing, and a missing one breaks an image.
- Images load only from inside the deck's folder. A path with `..` that leaves it, an absolute path, a protected
  location inside it, and a remote image show alt text, under UTERM-030 "Slide images". The same deck opened as a
  document follows the viewer's volume rule, which is wider.

Rationale: a deck written as a document resolves images against its own folder, and that folder is the one the user
granted under UTERM-032. Each slide renders alone, so a definition placed at the end of the deck, as documents often
do, would leave `![alt][logo]` as literal text on every slide but its own. A deck-level or per-slide images directive
would make paths differ from the document view and add surface to the deck format, for a need nobody named. Converged
in 1 pass.

### How it ends

Original question: whether Ctrl-C in the source terminal is the only way to end it, or a Stop command joins Next and
Previous.

Decision: a Stop Presentation command joins Next Slide and Previous Slide, in the palette, with no key. Stop, Ctrl-C in
the presenter's terminal, Revoke, and the end of the source session all end the presenter the same way. Its commands
and keys leave, and the pane keeps the last slide. (autonomous)

- Stop ends the script. The presenter treats a read that fails as ended, after Revoke, as the end too, and exits
  without an error.
- Stop is reachable where stepping is: in the slide pane, after the user clicks it, per UTERM-024's rule for a pane
  whose first body a program sent.

Rationale: during the talk, focus sits in the slide pane. Ctrl-C reaches the presenter only from its own terminal, so
ending with it means moving focus there first. A Stop in the palette ends it from the slide pane. A palette entry
widens no key approval, under UTERM-024 "What a remembered approval covers". A key for Stop, such as Escape, would end
the talk on one stray press, and a rerun opens a second slide pane and starts from slide 1.
Stopping on a step past the last slide contradicts "Stepping". A host-owned Stop Controller in the badge menu, beside
Revoke, would serve every controller, but is an addition that adds little here beside Revoke and this command.
Converged in 1 pass.

### Layout

Original question: where the slide pane sits beside the starting terminal, and its weight.

Decision: the presenter's first layout request splits the starting terminal's slot in a row, with the terminal on the
left and the slide pane on the right at two thirds. When that layout is refused for room, the presenter asks once more
at equal weight. Amended 2026-11-16; see Decision Log.

```janet
{:split :row :children [{:pane me} {:open :text-viewer :control :remote-controlled :weight 2}]}
```

- A layout is refused, not shrunk, when a pane would fall under its 200-point minimum width. At two thirds, the
  terminal's slot needs about 605 points. At equal weight, it needs about 405.
- After a refused layout, the presenter reads its own mode again. A disconnected terminal ends it with the enable-step
  message, per "How the starting terminal joins the layout". Otherwise it retries at equal weight. A refused layout
  changes nothing, so the retry starts from the same tree.
- When the equal layout is refused too, the presenter ends with a message that says to widen the terminal's pane or
  close a stale slide pane.
- The split replaces only the starting terminal's slot. Other panes in the window keep their places.
- The slide pane opens remote-controlled, so it is a member of the presenter's group and takes its keys, per UTERM-024.
- A column split is out, since "Slides only, beside the terminal" settles a slide beside the terminal.
- The user may drag the split, and the slide refits, per UTERM-030.

Rationale: the right side matches uniterm's primary split, Split Right. A slide on the left breaks that convention for
a reading-order preference. Script options for the side and the weight add flags to a command line users copy, while
dragging the split already covers the need.

The weight: the user chose two thirds with a retry at equal. The terminal holds only the presenter's start message and
its errors, so the slide takes the room where the slot has it, and the presenter still starts wherever equal weight
starts. The split then depends on the slot's width. Equal weight alone was weighed for giving the same split on every
window. Two thirds alone refuses slots under about 605 points. Three quarters refuses half of a 1440-point window.
Holding a pane at its minimum instead of refusing would change UTERM-004's layout contract.

### Slide size

Original question: `show-markdown` caps a slide at 12 KiB, far more than a slide needs. What the presenter does with a
slide over it: refuse to start, or show an error slide in its place.

Decision: the presenter refuses to start. Before it opens any pane, it measures every slide as it will send it, with
its definitions. When any slide is over the cap, it opens nothing and ends with an error that lists every oversized
slide. (autonomous)

- Each entry gives the slide's number, its line range in the deck, its own size, and the bytes its definitions add, so
  the user knows what to cut.
- The error prints to the presenter's terminal and posts to the status bar.

Rationale: the presenter holds the whole deck at start, so it can find every bad slide before the talk, and the user
fixes them in one pass. Opening nothing keeps a rerun after the fix clean, with no stale slide pane. An error slide in
place shows the problem to the audience mid-talk. A warning at start followed by an error slide leaves the fix to a
stop and rerun, which nests a second split. Splitting a slide invents structure the author never wrote, and a cut can
land inside a fence or a table. Truncating drops content silently. Raising the cap would add a delivery contract to
the viewer for slides no one could read at the shrink floor. Converged in 1 pass.

### How the starting terminal joins the layout

Original question, found in review: a first layout must place its anchor, and every open pane it places must be
remote-controlled. A terminal the user opens starts disconnected, and only the user enables it. So the presenter's
layout is refused on a fresh terminal.

Decision: the user enables remote control on the starting terminal before running the presenter, and may disconnect
it again once the slide shows. (autonomous)

- At start, the presenter reads its own pane's mode with `uniterm/list-windows`, which answers even for a
  disconnected pane. When the terminal is disconnected, it ends before any layout. Its error names the step and where
  to take it, and lists any deck errors in the same message.
- A layout refused for the same reason, such as after the user disconnects between the check and the layout, ends the
  presenter with the same message and leaves no pane.
- Once the slide shows, the start message tells the user that the terminal may be disconnected again. A disconnected
  source keeps its calls to the panes it already owns, per UTERM-004, so stepping, Stop, and slide images keep working.
- While the terminal is remote-controlled, every session in that pane, its other tabs included, follows the
  controlled clipboard policy, so a program's clipboard write there asks. An approved controller started from that
  shell may also open tabs in it, read its title and folder, and anchor layouts at it. No controller can send a
  terminal input, since a terminal refuses every applet command.

Rationale: the step keeps every accepted contract. UTERM-004 leaves enabling a disconnected pane to the user, and
ADR-09 says remembered permission does not override a disconnected pane. Disconnecting after the layout bounds the
exposure to the seconds the layout takes, and leaves the terminal as it was. A layout that may place a disconnected
source would reverse UTERM-004's rule that a disconnected source cannot be rearranged, and a remembered approval would
then split it with no user action. Enabling the source for the run from the approval sheet would change the sheet and
the control-mode lifecycle, and would need a lease for two runs from one shell. Both are additions. Converged in 1
pass.

### Version skew

Decision: the presenter adds no contract between deploy units. The example lives in the repo and versions apart from
the app. (autonomous)

- A newer example on an older app is refused at load, since an older build refuses a declaration kind it does not
  know, per UTERM-024 and UTERM-032.
- An older example on a newer app works, since a Janet name and a schema version never change meaning.
- A viewer without the slide style refuses the first slide, which ends the run with the cause named.

## Design Decisions (Open)

None.

## Risks

- **The prerequisites change during implementation** — likelihood: low, impact: medium. Mitigation: UTERM-024,
  UTERM-030, and UTERM-032 are accepted, so a change to one is an amendment that names this proposal in its Impacts.
- **UTERM-015 M4 is unbuilt and large** — likelihood: high, impact: medium. Slide images wait on it. Its gate,
  UTERM-004 M6, is done. UTERM-032 uses only some of M4: the confined open and the protected-location list. It keeps
  its remembered folders in a store of its own. Mitigation: it is queued, and UTERM-032 M1 starts after it, so the
  grant never ships without its checks.
- **Stepping needs focus in the slide pane** — likelihood: medium, impact: low. During a live demo in another pane, the
  user clicks back into the slide pane to step. Accepted: the click is the step back into the talk, and the start
  message says to click the slide. A key pressed in another pane belongs to that pane, and UTERM-031, which weighed keys
  there, is retracted. Amended 2026-11-20; see Decision Log.
- **Running the presenter after a relaunch leaves a second slide pane** — likelihood: high, impact: low. The restored
  group has no owner, and the new run opens its own. Accepted: the user closes the stale pane. UTERM-033 adds reclaiming.
- **Stopping and running again in the same launch nests a second split** — likelihood: high, impact: low. Rehearsal
  reruns the same deck. Each run splits the starting terminal's slot again, so the stale slide pane stays and the
  terminal keeps a third of what it had, or half when the rerun falls back to equal weight. On a full 1440-point
  window, the first rerun falls back, and a second one is refused. UTERM-033 does not offer a group whose owner ended
  in this launch. Accepted: the user closes the stale pane, and the terminal takes its width back. The refusal message
  says so.
- **The remote-control step is skipped or left on** — likelihood: high, impact: low. A user who skips the step gets a
  refusal before any pane opens. A user who leaves the terminal remote-controlled gets a clipboard prompt when a
  program in one of its tabs copies, and later controllers from that shell may anchor there. Mitigation: the refusal
  names the step, and the start message says the terminal may be disconnected once the slide shows.
- **A deck file is untrusted input** — likelihood: medium, impact: medium. Mitigation: the text viewer already renders
  untrusted Markdown. The presenter passes content through and adds no rendering of its own. Deck text it prints or
  posts is escaped.
- **Users copy the example's deck format** — likelihood: medium, impact: medium. A later bundled presenter, UTERM-026's
  speaker notes, or UTERM-029's sources would need to read decks written for the example. A notes block or a
  front-matter rule would change how an existing deck renders. Mitigation: "Deck format rules" settles the format with
  no version marker. A deck without a marker reads under these rules in every later presenter. A later format that
  changes rendering opts in by a marker of its own.

## Milestones

### M1: Present a Markdown deck

**Status:** NOT STARTED

- Starting the presenter on a Markdown deck opens a slide pane beside the starting terminal, in the slide style
- The arrow keys, Page Up and Page Down, Space, and the palette step the deck after the user clicks the slide pane or
  moves focus into it. Before that, the keys reach the terminal, and the start message says to click the slide
- A deck that is empty, or holds only separators and whitespace, opens no pane and says so
- Two separators in a row make no blank slide, a `---` inside `<pre>`, `<script>`, or `<style>` never splits, and a
  deck that starts with YAML shows it as text
- A slide's images load from the deck's folder
- A `---` under a line of text, inside a fence, or inside a multi-line HTML comment with a blank line in it never
  splits a slide. A deck that starts with `---` opens on its first real slide
- A fence left open runs to the end of the deck, as the document view shows it, and the presenter posts a warning at
  start
- An image by reference whose definition sits on another slide loads. A slide's own definition of a label wins, and a
  label with non-ASCII characters is always sent
- Sent definitions follow a blank line and never render as text. A slide that leaves a fence or an HTML block open is
  sent without them
- A deck reached through a symlink loads its images from the canonical folder, and the example's notes say images load
  only from inside the deck's folder
- Stepping past either end leaves the slide in place and posts a status message
- Ending the presenter removes its commands and keys, and leaves the pane showing the last slide. A re-render after
  that shows its images as alt text
- Stop Presentation in the palette ends the presenter from the slide pane, and binds no key
- Revoke ends the presenter without an error, since it treats a read that fails as ended as the end
- The example reads commands with a timeout of at most one second, so one Ctrl-C in its terminal ends it within that
  time while it waits
- With the starting terminal disconnected and the slide pane closed, Revoke Controller from the palette, with the
  terminal focused, ends the presenter
- When the source shell exits or its pane closes, or the presenter gets SIGTERM, its commands and keys leave and the
  slide pane keeps the last slide
- The example catches its own errors during the talk and posts them to the status bar, where the user looking at the
  slide sees them
- The example's usage line names the remote-control step, and its start message says how to end it
- The slide pane opens to the right of the starting terminal at two thirds, and the starting terminal keeps focus
- In a slot too narrow for two thirds but wide enough for equal weight, the slide opens at equal weight
- In a slot too narrow for either, the presenter opens no pane, and its message says to widen the terminal's pane or
  close a stale slide pane, not only that the layout does not fit
- A presenter that ends after a refused layout shows the host's refusal reason beside the widen-or-close hint, so a
  refusal for another reason, such as an open sheet, is never reported only as too narrow
- The presenter reads its own mode again after the equal-weight refusal too, so a terminal disconnected between the two
  attempts ends with the enable-step message
- Started from a disconnected terminal, the presenter opens no pane, and one error names the enable step and lists any
  deck errors
- A layout refused because the terminal was disconnected after the check ends the presenter with the same message, and
  leaves no pane. The presenter tells this refusal from others by reading its own mode again, not by its error text
- After the user disconnects the starting terminal once the slide shows, stepping, Stop, and slide images still work
- A deck with slides over the size cap opens no pane, and its error lists every one, with its line range, its own
  size, and its definitions' bytes. When a fence is left open, the error names it as the likely cause
- A deck with many definitions at its end, each used by one slide, starts, and every image loads
- Deck text in a terminal or status message is escaped, with control bytes shown visibly
- The check at start refuses a slide that holds a control character other than tab, line feed, or carriage return.
  Every slide under the cap then fits the helper's JSON limit, base folder and style included
- A send that fails mid-talk, such as a busy refusal, leaves the presenter and the pane on the current slide and posts
  the error to the status bar
- A first slide that fails to send, such as on a viewer without the slide style, ends the run with an error that names
  the cause
- A UI test runs the repo's example file on a synthetic deck in the real app and captures each step on screen
- `uniterm lint` passes on the example file

## Decision Log

- 2026-11-15: The presenter is a controller over existing applets, not an applet.
- 2026-11-15: Markdown is the one deck source on the hot path. The user confirmed it.
- 2026-11-15: Speaker notes moved off the hot path to UTERM-026. The user chose this after the design critic found that
  one window shows the audience every pane.
- 2026-11-15: Readable projected text and slide images are required. The user chose both, and they became UTERM-030.
- 2026-11-15: Stepping uses the arrow keys and Page Up and Page Down. The user noted that people step slides with plain
  arrow keys.
- 2026-11-15: The deck's folder is granted at run time, and the deck arrives on stdin. The user chose this, and it
  became UTERM-032.
- 2026-11-15: A slide pane beside the terminal is enough for the hot path. The user chose this. Pane zoom stays in
  UTERM-026.
- 2026-11-16: Space steps forward. The user chose it. The earlier reason for dropping it, that Space types text, does
  not hold in the slide pane under UTERM-024's opt-in rule.
- 2026-11-16: The deck is an argument, not stdin. The user corrected it. The presenter ships as an example script in
  the repo. The user chose this.
- 2026-11-16: Review start: 1 milestone, 7 settled decisions, 6 risks, no `**Live after:**` lines or row gates, 4 open
  questions. Out of scope: speaker notes, pane zoom, and the presenter view, which are UTERM-026; other deck sources
  and Go to Slide, which are UTERM-029; and bundling the presenter in the app. At the commit "Settle and accept
  UTERM-024's controller input channel". The user asked for an autonomous review of the open questions.
- 2026-11-16 (autonomous): a `---` line after a blank line, outside a fence and outside an HTML block that runs past
  blank lines, splits slides. Whitespace-only slides are dropped. Converged in 1 pass. A heading boundary, an HTML
  comment separator, and every CommonMark thematic break were weighed.
- 2026-11-16 (autonomous): images resolve against the deck's canonical folder, and the deck's reference definitions
  apply to every slide. Converged in 1 pass. A deck-level and a per-slide images directive were weighed.
- 2026-11-16 (autonomous): added the open question "Where the demo runs". The critic found that `uniterm run` holds
  its terminal for the whole run, so the terminal beside the slide cannot run the demo. "How it ends" and "Layout" wait
  on it.
- 2026-11-16 (autonomous): the presenter runs in the background of its starting terminal, with `&`, and that terminal
  runs the demo. It writes nothing to the terminal after it starts. Converged in 1 pass. A foreground console, a demo
  terminal the presenter opens, and a detach option on `uniterm run` were weighed.
- 2026-11-16 (autonomous): a Stop Presentation command in the palette, with no key, ends the presenter. Stop, Ctrl-C,
  Revoke, and the source session's end all end it the same way. Converged in 1 pass. Ctrl-C only, Stop on Escape, and
  stopping past the last slide were weighed. A host-owned Stop Controller in the badge menu was an addition and could
  not win.
- 2026-11-16 (autonomous): the slide pane opens to the right of the starting terminal at equal weight, in a row split
  of that terminal's slot. Converged in 1 pass. A larger slide, a slide on the left, and script options were weighed.
- 2026-11-16 (autonomous): a deck with a slide over the cap refuses to start, before any pane opens, and lists every
  oversized slide with its line range, its own size, and its definitions' bytes. Converged in 1 pass. An error slide, a
  warning followed by an error slide, splitting, truncating, and raising the cap were weighed.
- 2026-11-16 (autonomous): narrowed the images decision, settled earlier in this review. It said the presenter "sends
  the deck's definitions with each slide". A deck with many definitions at its end would then push every slide over
  the cap. The presenter now sends only the definitions a slide may name, erring toward sending.
- 2026-11-16 (autonomous): fixed a bug the critic found. The helper's JSON writer spent six bytes on a line break, and
  the inline cap's budget counts two. A slide of short tab-indented lines passed the cap and failed in the helper. The
  commit "Write line breaks and tabs as two-byte JSON escapes in the script helper" has the fix.
- 2026-11-16 (autonomous): coherence review, full pass. Added the open question "How the starting terminal joins the
  layout": a first layout must place a remote-controlled anchor, and a fresh terminal is disconnected. Settled it as an
  enable step checked at start, with the terminal free to disconnect once the slide shows. Converged in 1 pass. A
  layout that places a disconnected source and enabling the source from the approval sheet were weighed, and both are
  additions.
- 2026-11-16 (autonomous): amended the risk "Stepping needs focus in the slide pane". It said "likelihood: medium,
  impact: low. During a live demo the user clicks back into the slide pane to step. Accepted: keys that work from the
  terminal are UTERM-031." The demo now runs in the starting terminal, so focus sits there in every demo, and UTERM-031
  declines keys from the terminal for now. It is now high and medium, mitigated by the start message, the click, and
  Focus Pane Right. The Summary narrows its clicker claim to while the slide pane has focus.
- 2026-11-16 (autonomous): amended "How it starts", which named `uniterm run presenter.janet deck.md`, to add the
  background `&`. Amended "Stepping" to add Stop Presentation beside Next and Previous. Both follow decisions of this
  review.
- 2026-11-16 (autonomous): coherence fixes. "Where the demo runs" bounds the presenter's terminal output to before its
  first slide. The first risk's mitigation was discharged, since the three prerequisites are accepted. The UTERM-015 M4
  risk's open line is settled by UTERM-032 M1 starting after it. The deck format risk now states its recovery path: a
  deck with no marker reads under these rules for good. Added the risk of a nested split on a rerun in the same launch,
  and a "Version skew" decision. Routed fourteen checks to M1.
- 2026-11-16 (autonomous): coherence re-check, pass 2: converged. Routed five checks to M1: Revoke Controller from the
  palette after the terminal is disconnected, a refused layout read by the presenter's own mode, the start message as
  the first slide shows, only wire failures printing after it, and a refusal of control characters that keeps every
  slide within the helper's JSON limit.
- 2026-11-16 (autonomous): filed the bug `20261116-disconnected-source-badge-hides-live-controller`, not confirmed.
  The critic found that a disconnected pane a live controller acts from shows no badge, so Revoke is reachable only
  from the palette.
- 2026-11-16 (autonomous): risk review. Every risk carries a likelihood, an impact, and a mitigation or an acceptance.
  None is high likelihood and high impact. The deck format is the one-way door, and it is listed with its recovery
  path. Added the risk that the remote-control step is skipped or left on. The two accepted risks are the stale slide
  panes after a relaunch and after a rerun, both rated high and low.
- 2026-11-16: Review gate: the user overturned "Where the demo runs". What runs in any other pane or tab is the
  user's business, and a demo runs in another pane or tab with nothing added. The finding it answered, that the
  presenter's terminal is busy, blocks nothing. Removed the decision, the background `&` and its amendment to "How it
  starts", the output rules, and the checks built on them. Rewrote the rationale of "How it ends": Stop stays, since
  focus sits in the slide pane during the talk. Restored the stepping risk to medium and low, accepted on a click into
  the slide pane, since UTERM-031 now declines keys from other panes. Reopened the layout's weight as "Layout weight",
  since its rationale was the demo. The side and the row split stay.
- 2026-11-16: UTERM-031 is retracted. Its Impacts line and the stepping risk said UTERM-031 "declines keys from other
  panes for now". They now say it is retracted, since a key pressed in another pane belongs to that pane.
- 2026-11-16: Layout weight: the slide opens at two thirds, with one retry at equal weight when the layout is refused
  for room. The user chose this over equal weight alone, two thirds alone, and a change to UTERM-004's layout contract.
  The critic found that a layout under a pane's minimum width is refused, not shrunk. Amended "Layout", which said
  "at equal weight", and restated the rerun risk for the new weight.
- 2026-11-16 (autonomous): coherence re-check, pass 3, on the changes since the review gate: converged. Routed two
  checks to M1: a refused layout's message carries the host's reason, and the mode is read again after the second
  refusal.
- 2026-11-16 (autonomous): ADR candidate (hard to reverse): a deck written for the presenter reads the same in every
  later presenter, and a format change that alters rendering opts in by a marker. Declined: the user chose no ADR, and
  UTERM-026 and UTERM-029, which could break it, depend on this proposal.
- 2026-11-16: Accepted. The user chose it after the review gate. No ADR written.
- 2026-11-20: ADR-12 was retracted, and UTERM-024 no longer disarms a controller's keys after a program-driven
  change. Amended the risk "Stepping needs focus in the slide pane". It said "The slide's keys also start disarmed until
  the user clicks it, per UTERM-024." That sentence is gone. The click into the slide pane is still needed, since the
  presenter's layout request leaves focus in the starting terminal.

## References

- ADR-03: restored state never runs a program
- ADR-09: control authority requires authenticated identity and explicit scope
