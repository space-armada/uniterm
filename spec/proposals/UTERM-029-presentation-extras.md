# UTERM-029: Presentation Extras

**Status:** accepted
**Created:** 2026-11-15
**Updated:** 2026-11-27

## Dependencies

- UTERM-025, for the presentation controller this extends
- UTERM-024 M2, for the presenter's commands and keys
- UTERM-030 M2, for slide images, which PDF pages and listed images extend
- UTERM-032 M1, for the input file, which this proposal extends to a PDF and an image folder
- UTERM-007, for the sandboxed document helper that draws PDF pages
- UTERM-026, for the `notes:` syntax that wrapper decks use, and the notes window the index moves to

## Impacts

- UTERM-032 — "The declaration and the host functions", "The input file is read by the command", "Calls without an
  input file", and the sheet line: a PDF and an image folder join text as input kinds, under a new edition of the declarable
  `input-file` kind. The command opens a PDF and passes its descriptor instead of reading text. The UTF-8 check and the
  size cap apply to text input only. New host functions return the kind, the input's base name, a PDF's pages, and a
  folder's images, which amends "No function returns the file's own path". `input-text` raises for a PDF or folder
  input. The sheet line and the stored folder kind's meaning name PDF pages, with no change to the stored version.
- UTERM-030 — "Slide images": a slide image may name one page of a PDF in the granted folder, drawn in the sandboxed
  document helper. The viewer takes it in place at schema 0.0, with no minor, per UTERM-063. Amended 2026-11-27; see Decision Log.
- UTERM-007 — the document helper's protocol gains a page-raster request and a page-count-and-outline request, each on
  a descriptor the app passes. Each request starts and ends its own helper, as its other decodes do. This supersedes in
  part its M1 check that "a PDF or Markdown pane starts none": a pane showing a PDF page reference starts a helper for
  each draw, which ends with the draw. UTERM-007 takes a "Superseded in part by UTERM-029" marker there.
- UTERM-025 — "Stepping" and "Deck format rules": the presenter gains Go to Slide, First Slide, and Last Slide, and a
  deck may name PDF pages. Its Impacts line for this proposal cites a risk that this review replaced.
- UTERM-026 — "Speaker notes" and "A second window": wrapper decks carry notes in its syntax, and Go to Slide's index
  moves to its notes window once that window exists.
- UTERM-003 — ScriptWire gains a message that carries the input file's descriptor. ScriptWire is at 0 under UTERM-063, so the message lands in place after UTERM-063 M2. Amended 2026-11-27; see Decision Log.

## Summary

Deck sources beyond Markdown, and Go to Slide, for the presentation controller. None is required. UTERM-025 presents a
Markdown deck without them.

## Motivation

People already have decks in other forms: a PDF exported from another tool, a folder of images, an HTML deck. A long
talk also needs a way to jump to a slide during questions.

## Design Decisions (Settled)

### Deck sources

Original question: which non-Markdown deck sources to build, and where each gets notes once UTERM-026 adds them. A PDF
reaches the viewer today only through `uniterm/send`, capped at 1 MiB, and the viewer shows a PDF as one continuous
column. An image folder can step through UTERM-006 M4's show-by-path. Stepping an HTML deck needs page JavaScript or
trusted input from UTERM-019. The notes half is its own question, "Notes for PDF and image-folder decks".

Decision: a bare PDF and a folder of images are deck inputs. The presenter turns each into slides of the Markdown body,
one page or one image per slide. HTML decks are deferred. (autonomous, judge)

- The user runs `uniterm run presenter.janet talk.pdf` or `uniterm run presenter.janet ~/talks/pngs/`. UTERM-032 is
  amended so the input may be a PDF or a folder, per "Input kinds and host functions".
- The command opens the input with the invoker's access, as UTERM-032 requires for text. For a PDF, it passes the open
  descriptor to the app over ScriptWire and reads no bytes itself. For a folder, it lists the folder through its
  descriptor. The granted folder is the PDF's folder, or the input folder itself.
- The app checks that a PDF's descriptor is a regular file, then hands it to the sandboxed document helper, which
  returns the page count and the outline titles. The script gets those, and the folder's image names, because the
  invoker read them through its own open.
- Nothing the app reads with uniterm's grants returns to the script. The app opens slide images and PDF pages under the
  grant, as UTERM-030 opens every slide image, and they reach only the pane's pixels.
- Each slide names its page or image as a slide image, under UTERM-030 "Slide images". A page is named
  `![](talk.pdf#page=3)`, per "PDF page references". A PDF page is drawn as a bitmap
  in the sandboxed document helper, from a descriptor the app opens under the grant, never with PDFKit in the app.
- The images of a folder deck are its files whose name extension the viewer serves as an image, in natural name order.
  The command decodes nothing. A listed file that fails to decode shows alt text on its slide, as any image does.
- Outline titles and file names are untrusted, so the presenter escapes them in the Markdown it generates.
- Every slide is the Markdown body, so stepping, Go to Slide, and the slide keys work as they do for a Markdown deck.
- HTML is deferred. A reveal.js or similar deck served on a loopback address already presents in the browser applet
  and steps with its own keys. What waits is the presenter's integration: Go to Slide and notes.

**Revisit:** when UTERM-019 M3, page JavaScript, is done, and the browser has a design for loading a local deck under a
scope. File a proposal for HTML decks then.

Rationale: a PDF and an image folder are the two exported forms the Motivation names, and the user runs either one
without writing a deck. One renderer and one slide body serve every source, so keys, Go to Slide, and the index need no
second path. Drawing pages in the helper keeps PDF parsing out of the app, since ADR-07's PDF exception covers only
PDFKit's view. Opening the input in the command keeps UTERM-032's rule that a remembered folder gives a program nothing
it could not read itself. An app-side open would return a PDF's outline to any program that runs the approved
presenter. A new PDF slide body would be a second renderer and a second body to vet for typed text. Making the deck's
folder a path-reading scope would reverse UTERM-032's settled grant. Driving the image viewer would let its own keys
move the image without telling the presenter, since remote callers get no applet events. HTML needs UTERM-019 and a
scoped `file:` load, which the browser refuses today. The judge ruled after three passes on budget. The critic and
the reviewer moved on evidence each pass: the helper rule, then the trust rule in UTERM-032.

### Input kinds and host functions

Found in review: the new inputs need a rule for which kind a file is, and the script needs functions to read them.

Decision: the command decides the kind from its open descriptor and the name. A directory is a folder input. A regular
file whose name ends in `.pdf`, in any letter case, is a PDF input. Every other regular file is text, under UTERM-032's
rules as they are. (autonomous)

- A `.pdf` that does not parse, or is locked, ends the run after approval with a message, before any pane opens. A text
  file that holds PDF bytes fails UTERM-032's UTF-8 check, as it does today.
- A script declares `{:kind :input-file}`, and the kind's edition moves with the new inputs, so an approval made at the
  earlier edition no longer covers it and the user is asked again. A script written for text only that is given a PDF
  fails by name when it calls `input-text`, and one given a folder fails the same way.
- `(uniterm/input-kind)` returns `:text`, `:pdf`, or `:folder`. `(uniterm/input-name)` returns the input's canonical
  base name, not its path, so a generated reference names the file inside the granted folder.
- `(uniterm/input-pages)` returns a PDF input's page count and its outline titles by page. `(uniterm/input-images)`
  returns a folder input's image names in order. Each raises for another kind.
- `(uniterm/input-text)` raises for a PDF or folder input, with a message that names the kind.
- The sheet line reads "Let the text viewer show images and PDF pages from /Users/me/talks/demo or a folder inside
  it, in panes it controls", for every kind. The stored folder kind keeps its version, and its meaning covers PDF pages.

Rationale: the command reads no PDF bytes, so the kind cannot come from sniffing content. The name is what the user
chose. A wrong name fails closed: a `.pdf` that is not a PDF ends the run, and a PDF named otherwise fails as text. A
new stored version would make an older build read the whole third store as newer, which UTERM-032 rejected. PDF pages
reach only the pane, as slide images do, and parse only in the sandboxed helper, so a remembered folder that comes to
cover them gives a program nothing new. One sheet line keeps the stored permission free of the input kind.

### Drawing PDF pages

Found in review: stepping a large PDF parses it on every step, since each helper decode starts and ends its own
helper under UTERM-007.

Decision: each page draw is one helper decode, which starts and ends its own helper, as UTERM-007's other decodes do.
The helper keeps no document between draws. A Markdown pane that shows a PDF page now starts helpers, which supersedes
in part UTERM-007's rule that such a pane starts none. M2 measures a step on a large PDF. If it misses its budget, a follow-up proposal designs a cache.
(autonomous)

Rationale: a cache would need an owner, a lifetime, a memory budget, and a rule for a grant that ends or a file that
changes between steps. A fresh decode per step gets all of those right by construction: no read after revoke, and no
stale page after a re-export. The cost is measured before anything is built to avoid it.

### PDF page references

Settled with "Notes for PDF and image-folder decks".

Decision: a Markdown image whose path names a PDF and whose fragment is `#page=N` shows that page, counted from 1. This
is the open parameter of RFC 8118, which Preview and browsers already follow. A PDF named with no fragment shows page 1.
(autonomous)

- The viewer keeps the page number for PDF names only. An image of another type ignores its fragment, as it does today.
- A page out of range, `#page=0`, a page that is not a number, a PDF that does not parse, and a locked PDF show alt
  text, as a missing image does. Other open parameters after the page, such as `&zoom=50`, are ignored.
- The PDF must lie inside the deck's folder, per UTERM-025's image rule.
- The reference renders in the slide style and in a Markdown document the user opened, so a deck reads the same both
  ways, per UTERM-025 "Deck format rules". Both draw the page in the sandboxed document helper, from a descriptor the
  app opens inside the folder the content may read. Markdown a program sends inline has no folder, so it names no PDF.
- An existing document holding such a reference changes from alt text to the page, with no format marker. That is
  accepted: the author plainly meant the image, and UTERM-025's marker rule guards against text shown that the author
  did not mean.
- The viewer's schema is at 0.0 and does not bump, so PDF page references land in place. An older viewer refuses a
  command it does not know by name, per UTERM-063. The presenter does not gate on a minor.

Rationale: generated slides and authored decks share one form, so the viewer never tells them apart. A form other
viewers already follow means a deck author does not learn a uniterm syntax. A query string such as `?page=3` names no
standard. A slides-only form would make a deck read differently opened as a document.

### Notes for PDF and image-folder decks

Original question: UTERM-026 adds speaker notes to Markdown decks as `notes:` HTML comments. A bare PDF or a folder of
images has no place for them. Where, if anywhere, these decks get notes.

Decision: a user who wants notes writes a Markdown deck that names each page or image, with `notes:` comments beside
them. A bare PDF or folder input has no notes. Notes use UTERM-026's syntax as it is accepted. (autonomous, addition)

- The deck names pages with "PDF page references". A slide holding only a page image lists by number in Go to Slide's
  index, unless the author adds a heading.
- A wrapper deck drifts when the PDF is re-exported with a page inserted: every later reference shows the wrong page,
  beside the wrong notes, and nothing signals it. The mapping is explicit in the deck, so the user can read and fix it.
- The addition is that PDF page references render in a document the user opened, not only on a slide.

Rationale: the wrapper reuses UTERM-026's notes and the deck format unchanged, and adds no second file or format. A
sidecar notes file would be a second deck format matched by order, drifting silently, and found by its name beside the
input. The command could read it with the invoker's access, so the grant is not what rules it out. A PDF's own text
annotations are a real convention for LaTeX Beamer through pdfpc, but they give image folders nothing, and a reviewed
PDF's comments would show as notes. Deferring until UTERM-026 is accepted would leave the page form open, which deck
sources need now. A starter deck printed by the presenter would save typing a long wrapper, and is an addition nobody
asked for. Converged in 1 pass.

### Go to Slide

Original question: registry commands take no arguments today. Options for naming the slide: a number typed in the
palette, which needs a new palette contract for an argument; a form, through UTERM-022's Questions applet; or a list of
slide titles as commands, which needs commands declared at runtime. UTERM-024 declares commands in the controller's
file only, so this adds runtime declaration.

Decision: the user types the slide number in the slide pane, as in Keynote and PowerPoint. The presenter declares these
commands in its file, under UTERM-024 as accepted. (autonomous)

- Go to Slide is bound to the digit keys 0 through 9. From a digit key, it starts or extends a number, shown in the
  status bar. From the palette, it shows an index slide of slide numbers and titles. The event's input field tells the
  two apart, per UTERM-024 "Events".
- Jump to Typed Slide is bound to Return, and jumps to the typed number. Clear Typed Slide is bound to Escape.
- First Slide and Last Slide are bound to Home and End, the image viewer's keys for the same steps.
- The index shows in the slide pane until the user jumps or presses Escape, which returns to the current slide. While
  it shows, Up and Down move a highlight from entry to entry and across its pages, and Return jumps to the highlighted
  slide. Left, Right, Page Up, Page Down, and Space page the index. A typed number still jumps from the index. The
  highlight opens on the current slide.
- A slide's title is its first heading. A PDF page's title is its outline entry. A slide with neither lists by number.
- The new keys widen the presenter's key set, so a remembered approval asks once more, per UTERM-024 "What a remembered
  approval covers".
- Escape and Return are not reserved keys. Return no longer activates a link the user tabbed to on the slide.
- Digits match as UTERM-024 matches keys. On a layout whose digit row needs Shift, such as AZERTY, typed numbers do
  not reach the presenter, and the index with its highlight is the way to jump.
- The index pages hold a fixed number of entries, chosen to fit at the shrink floor above a stated pane size.

Rationale: a number is how people jump in every presentation app, and digits in the slide pane keep focus where
stepping needs it. The index serves "the slide about X" with no new contract. Binding the digits to one command keeps
the palette from listing a digit row that carries no digit. Slide titles declared at runtime would reopen UTERM-024's
fixed registry, and a long deck would flood the palette with rows that match uniterm's own commands. A palette argument
or a list chooser drawn by uniterm is a new palette contract with one caller. A Questions form is unbuilt, and needs
the `ask-user` power. Typing in the presenter's terminal moves focus away from the slide. The index is projected to the
audience. Converged in 3 passes. Amended 2026-11-20; see Decision Log.

**Revisit:** when UTERM-026 M2, the presenter view, is done, move the index and the typed number into its notes window,
which the audience does not see.

**Revisit:** when a proposal adds UTERM-024's layout-aware key kind, bind the digits under it so typed numbers work on
every layout.

### Version skew

Decision: every contract this proposal changes ships in one app bundle with its peers, or is refused by name.
(autonomous) Amended 2026-11-27; see Decision Log.

- ScriptWire, between the `uniterm` command and the app, gains the descriptor message in place, since ScriptWire is at
  0 under UTERM-063. A mismatched command is refused by name, and a swapped bundle is caught by its identity check.
  Amended 2026-11-27; see Decision Log.
- The document helper ships in the app bundle and refuses a protocol mismatch at its hello, as it does today.
- The viewer's schema stays 0.0. A newer presenter on an older viewer is refused by name where its command changed. An
  older presenter on a newer viewer works, and a `![](x.pdf)` it sends now shows the page. That changes what an
  existing command renders, and is accepted for the reason in "PDF page references".
- An older build reads an approval at the `input-file` edition it does not know as newer, and keeps it unread. An
  older presenter declares the kind alone and fails by name when it calls `input-text` on a PDF or a folder.
- The stored folder kind keeps its version, so a build without this proposal reads a folder remembered by a newer one.
  That older build shows images only, which is narrower.

## Design Decisions (Open)

None.

## Risks

- **PDF page references are a format contract** — likelihood: medium, impact: medium. Authored decks and documents will
  hold `#page=N` references, and changing their meaning later would show the wrong page. Mitigation: the form is the
  standard RFC 8118 open parameter, so it never needs to change. A later change opts in by a marker, per UTERM-025's
  deck format risk.
- **A hostile PDF reaches the document helper** — likelihood: medium, impact: low. With a remembered folder, a program
  can run the approved presenter on a crafted PDF, with no sheet. Mitigation: pages and outlines are parsed only in the
  sandboxed document helper, per ADR-07 and ADR-10. A crash there ends a slide's image, not the app. A Markdown
  document the user opens can name any PDF its volume rule reaches, and the helper parses that too.
- **Wrapper decks drift on re-export** — likelihood: medium, impact: low. A page inserted in the PDF shifts every later
  reference and its notes, silently. Accepted: the mapping is plain in the deck, and a talk is rehearsed before it is
  given. A bare PDF input has no mapping to drift.
- **A remembered folder comes to cover PDF pages** — likelihood: high, impact: low. A folder remembered for a
  Markdown deck, before or after this proposal, lets the presenter show PDF pages from it with no new sheet. Accepted:
  pages reach only the pane, parse only in the sandboxed helper, and return nothing to the script. A program that can
  run the presenter could read those files itself. Amending UTERM-032's sheet line before its M2 ships keeps the stored
  meaning honest for every approval.
- **The amended prerequisites shift before they are built** — likelihood: medium, impact: medium. UTERM-030 M2 and
  UTERM-032 are unbuilt, and this proposal amends both. Mitigation: each amendment is listed in Impacts and lands in
  that proposal's text in the same review. Wrapper decks take UTERM-026's accepted `notes:` syntax, so a later change
  there is an amendment that names this proposal.
- **The new host functions are a published script API** — likelihood: low, impact: medium. Example scripts and users'
  copies will call `input-kind`, `input-name`, `input-pages`, and `input-images`. Mitigation: they exist only under
  the `input-file` kind, so a change in meaning moves its edition, and an older script fails by name on a kind it never
  read.

## Milestones

### M1: Go to Slide

**Status:** NOT STARTED

- Typing a slide number in the slide pane and pressing Return shows that slide, and the status bar shows the number as
  it is typed
- Go to Slide from the palette shows the index. A number and Return jump from it, and Escape returns to the current
  slide
- An index too long for one slide pages across slides that each fit the size cap, at the pane size the decision
  states, with each entry cut to one line
- While the index shows, Up and Down move the highlight across entries and pages, and Return jumps to the highlighted
  slide. The highlight opens on the current slide
- While the index shows, Home and End move the highlight to the first and last entry. Moving the highlight clears a
  typed number, and a typed number left standing wins over the highlight on Return
- In a pane below the stated size, the highlighted entry stays visible
- Home and End show the first and last slide
- A typed number out of range leaves the slide in place and posts the range
- A step key, or a pause of a stated clear interval, clears a typed number, so a stale digit never fires on a later
  Return. The interval is its own, not the read timeout
- On a slide, Return and Escape with no number typed do nothing and post nothing
- An outline title or heading that holds Markdown, such as an image reference, shows as text in the index
- Slide numbers count slides after whitespace-only slides are dropped
- A slide with no heading lists by number in the index
- Digit bindings fire for the top row on a US layout. On an AZERTY layout, Go to Slide from the palette and the
  highlighted index jump to a chosen slide
- A remembered approval of the presenter asks again once, and lists the new keys

### M2: PDF page references

**Status:** NOT STARTED

- `![](talk.pdf#page=3)` in a deck shows page 3 on the slide, and the same reference shows page 3 in the deck opened as
  a document
- A PDF named with no fragment shows page 1. A PNG named with a fragment shows the PNG
- A page out of range, a PDF that does not parse, a locked PDF, and a PDF outside the deck's folder show alt text
- Pages are drawn in the sandboxed document helper, never with PDFKit in the app
- A page is drawn at the pane's backing pixel size within the helper's pixel cap, and drawn again after a resize or a
  display change
- A step on a 100-page, 50 MB PDF shows its page within a stated budget on the reference machine, with the time and
  budget recorded in the As built block
- `#page=0`, `#page=abc`, `#page=3&zoom=50`, and `#zoom=50&page=3` behave as "PDF page references" says, and a PDF
  named in inline Markdown with no base folder shows alt text
- A name ending in `.PDF`, in any letter case, is a PDF name to the viewer, as it is to the command
- The `show-markdown` load reply never waits on a PDF page draw
- After Revoke, the next step reads no page
- A step, a reload, a new slide, or closing the pane ends any page-draw helper still running for the old slide
- Rapid stepping keeps at most a stated number of page-draw helpers running at once
- When a step misses the budget, M2 is done with the miss recorded, and a follow-up proposal for a cache is filed
- A file name with spaces, parentheses, `#`, or `%` in it loads when the deck escapes it
- A newer presenter on a viewer that predates PDF page references is refused by name, with a message
- A `notes:` comment beside a page reference does not show on the slide

### M3: PDF and image-folder inputs

**Status:** NOT STARTED

- `uniterm run presenter.janet talk.pdf` presents every page, one slide per page, with stepping and Go to Slide
- `uniterm run presenter.janet ~/talks/pngs/` presents every image in natural name order and skips files that are not
  images
- The command opens the input with the invoker's access and reads no PDF bytes itself. Nothing the app reads with
  uniterm's grants reaches the script
- The app refuses a passed descriptor that is not a regular file
- A locked or unparseable `.pdf` input ends the run after approval with a message, and opens no pane
- A listed file with an image extension that fails to decode shows alt text on its slide
- An image name with spaces, `#`, or `%` in it loads, since the presenter escapes it
- The kind follows the input's canonical name, so a symlink named `deck.pdf` to a file named otherwise gives a kind and
  generated references that agree
- A folder deck skips dotfiles, such as AppleDouble `._slide1.png` files, subdirectories, and entries that are not
  regular files, even with an image extension
- A PDF with a huge page count or outline, or a folder with a huge number of images, ends the run with a message
  instead of overflowing ScriptWire's frame cap or the slide size cap
- UTERM-032's "Calls without an input file" errors name the `input-file` kind that takes the input in use
- A text-only presenter given a PDF fails by name when it calls `input-text`, and given a folder fails the same way
- A symlink inside a folder deck that resolves to an image inside the folder is listed, and one that leaves it is not
- The page count, outline, and image limits are stated. Past a limit the run ends with a message naming it
- UTERM-007's M1 check that "a PDF or Markdown pane starts none" carries a "Superseded in part by UTERM-029" marker,
  with its paired Decision Log entry
- A PDF's outline titles fill Go to Slide's index
- The input kind follows "Input kinds and host functions", and `input-text` raises for a PDF or a folder with a
  message naming the kind
- The sheet line names images and PDF pages for every input kind
- A mismatched command is refused by name at the first message that changed, and a swapped bundle by its identity
  check. Amended 2026-11-27; see Decision Log
- A PDF re-exported mid-rehearsal with fewer pages shows alt text past its end, never another file's page
- A symlinked input names the canonical file in its generated references
- An older build reads an approval at the new `input-file` edition as newer, and keeps it unread

## Decision Log

- 2026-11-15: Split from UTERM-025, which narrowed to the hot path.
- 2026-11-16: Review start: 1 milestone, 0 settled decisions, 2 risks, no `**Live after:**` lines or row gates, 2 open
  questions. No out-of-scope statements. At the commit "Settle the presenter's keys and image access". The user asked
  for an autonomous review of the open questions.
- 2026-11-17 (autonomous): Go to Slide is the digit keys bound to one Go to Slide command, with Return to jump, Escape
  to clear, Home and End for the first and last slide, and an index slide from the palette. Converged in 3 passes.
  Number keys alone, separate digit commands, slide titles declared at runtime, a palette argument, a palette list
  chooser, a Questions form, and typing in the presenter's terminal were weighed.
- 2026-11-17 (autonomous, judge): a bare PDF and an image folder are deck inputs, opened by the command with the
  invoker's access and turned into slides of the Markdown body, with PDF pages drawn in the sandboxed document helper.
  HTML is deferred until UTERM-019 M3. The judge ruled after three passes on budget. A new PDF slide body, two
  renderers, an app-side open, path-reading scopes with the image viewer, and Markdown image decks alone were weighed.
  Split the notes half of the question into "Notes for PDF and image-folder decks". Filled the Impacts section.
- 2026-11-17 (autonomous, addition): a PDF or image deck gets notes only as a Markdown deck the user writes, naming
  each page as `![](talk.pdf#page=N)` with UTERM-026's `notes:` comments. PDF page references render on slides and in
  documents the user opens, which is the addition. Converged in 1 pass. No notes for PDF, a sidecar notes file, the
  PDF's own annotations, deferring, slides-only references, and a printed starter deck were weighed.
- 2026-11-17 (autonomous): split M1 into Go to Slide, PDF page references, and PDF and image-folder inputs, each with
  the checks the critique routed to it. Rewrote the Risks. The format risk's mitigation said "version it with
  UTERM-025's deck format", which has no version. The HTML risk left with HTML's deferral.
- 2026-11-17 (autonomous): coherence review, full pass. Restated the trust invariant: nothing the app reads with
  uniterm's grants returns to the script. The text had said the app never opens the input, which slide images do.
  Added "Input kinds and host functions": the kind comes from the descriptor and a `.pdf` name, `input-file` version 2
  takes the new kinds, and four host functions read them. Kept the stored folder kind's version, since a bump would
  stop every folder policy on an older build, and accepted that remembered folders come to cover PDF pages. Added
  "Drawing PDF pages": no helper cache, measured in M2. Folder images are chosen by extension, not decoded in the
  command. Added "Version skew". Filled Impacts and Dependencies. Routed fourteen checks to the milestones.
- 2026-11-17 (autonomous): coherence re-check, pass 2: not converged. Go to Slide's index gains a highlight that Up and
  Down move and Return jumps to, since typed digits do not reach the presenter on AZERTY and the index alone could not
  jump. Added a revisit hook on UTERM-024's layout-aware key kind. "Drawing PDF pages" and the UTERM-007 Impacts line
  now say they supersede in part UTERM-007's rule that a PDF or Markdown pane starts no helper. Routed nine checks.
- 2026-11-17 (autonomous): coherence re-check, pass 3: converged. Routed ten checks: helper teardown and a bound on
  running helpers, the budget-miss outcome, index keys for Home, End, and a typed number, symlinks in folder decks,
  stated input limits, the refusal of a version 1 presenter, and UTERM-007's supersede marker with its log entry.
- 2026-11-17 (autonomous): risk review. Every risk carries a likelihood, an impact, and a mitigation or an acceptance.
  None is high likelihood and high impact. The page reference form and the host functions are the one-way doors, and
  both are listed. Added the risks of amended prerequisites shifting and of the host functions as a published API.
  Accepted the one high-likelihood risk, remembered folders coming to cover PDF pages, at low impact.
- 2026-11-17 (autonomous, addition): First Slide and Last Slide on Home and End, settled in "Go to Slide". The Summary
  names Go to Slide only.
- 2026-11-17: Review gate: kept all. The user kept bare PDF and folder inputs, PDF page references in documents as well
  as slides, Home and End, and the deferral of HTML decks.
- 2026-11-17: No decision earns an ADR. The trust rule that nothing read with uniterm's grants returns to the script is
  UTERM-015's and UTERM-032's, and PDF parsing outside PDFKit's view is ADR-07's and ADR-10's.
- 2026-11-17 (autonomous): UTERM-026 was accepted during this review, with its `notes:` syntax unchanged. Go to
  Slide's revisit hook fired on that acceptance with no window to move to, so it now waits on UTERM-026 M2.
- 2026-11-17: Accepted. The user chose it after the review gate. No ADR written.
- 2026-11-20: ADR-12 was retracted. The user retracted it and set that a program's operation behaves as the user's.
  Amended the rationale of "Go to Slide". It said a Questions form "takes no focus under ADR-12, so the user clicks into
  it and back out mid-talk". That reason rested on ADR-12, so it is gone. The decision stands on its other reasons: a
  form is unbuilt and needs the `ask-user` power.
- 2026-11-21: Scheduled as UTERM-029 M1-M3 in queue.md.
- 2026-11-23: From UTERM-056's acceptance. "Version skew" said "ScriptWire needs an exact match at the hello, per ADR-13's
  exemption", and the check had a mismatched command refused only at the hello.
- 2026-11-27: From UTERM-063. ScriptWire and the viewer's schema are at 0 and do not bump, and permission kinds carry an
  internal edition in place of a version. This proposal's changes land in place after UTERM-063 M2.
  - Amended "Version skew". It said ScriptWire "gains the descriptor message under a new protocol version", and that the
    viewer "advertises PDF page references with a schema minor". An older build "refuses `input-file` version 2 at
    load. An older presenter declares version 1 and gets text only."
  - Amended "PDF page references". It said "The presenter requires it before it sends a slide that names a PDF, so an
    older viewer refuses the run instead of showing alt text."
  - Amended "Input kinds and host functions". It said a script declares `{:kind :input-file :version 2}`, and that
    "Version 1 keeps text only". The kind is named alone now, and a text-only script given a PDF fails by name at
    `input-text`. A user whose approval was made at the earlier edition is asked again.
  - Amended the Impacts lines for UTERM-030, UTERM-003, and the input-file kind, the risk on the new host functions,
    and the M2 and M3 checks that named a minor, a version 1 presenter, or a new protocol version.
  - Open: UTERM-063 gives a changed permission no way to say which edition a script needs, so a script that wants
    PDF inputs cannot declare it. UTERM-063's "Permissions carry no version" records that as undone.
- 2026-11-27: Brought in line with UTERM-063 at the user's direction. "Version skew" opened with "every contract this
  proposal changes ships in one app bundle with its peers, or is refused by version". Nothing is refused by version at
  0, so it now says "refused by name". The rest of the proposal was read and already lands its changes in place.

## References

- None.
