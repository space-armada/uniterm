# UTERM-030: Text Viewer Slides

**Status:** accepted
**Created:** 2026-11-15
**Updated:** 2026-11-27

## Dependencies

- UTERM-007, for the text viewer, its Markdown page, and its remote schema
- UTERM-004, for remote control of a viewer pane
- UTERM-015, for the path-reading power and its checks, built in its M4
- UTERM-032, for the input file's folder the user grants when starting the controller
- UTERM-024, for controller keys, which the Markdown page opts in to

## Impacts

- UTERM-025 — the whole proposal: this is a required prerequisite of the presentation controller. Slides need text
  that fills the pane, and images.
- UTERM-024 — "Which panes take a controller's keys": the text viewer's page opts in to controller keys. The arrow keys step
  slides, so a slide's overflow rule cannot rely on scrolling by keyboard.
- UTERM-007 — "Control levels": the viewer's remote schema gains a style argument and a base folder argument. The
  schema is at 0.0 under UTERM-063 and does not bump, so both land in place after UTERM-063 M2. Amended 2026-11-27;
  see Decision Log.
- UTERM-006 — its remote schema is at 0.0 as well, so a new optional argument lands in place there too. From schema 1.0
  a new optional argument counts as a minor bump.
- UTERM-032 — "Slide images": no reply about slide content carries a landing anchor, which keeps UTERM-032's rule
  that the grant returns nothing to the script.
- UTERM-029 — "PDF page references": amends "Slide images" and "Version skew". A slide image may name one page of a
  PDF, drawn in the sandboxed document helper, and the argument lands in place at schema 0.0.
- UTERM-004 — "How the grant reaches the viewer": the applet command contract gains a capability that a command's
  schema declares, so dispatch hands an applet more than a name and arguments.

## Summary

Three text viewer changes a slide deck needs. A slide style lays Markdown out to fill the pane, instead of a 15px
document column. Images in a slide load from the deck's folder, instead of showing alt text. The Markdown page takes a
controller's keys, so the arrow keys step slides.

## Motivation

The text viewer is built to read documents. Its stylesheet sets body text at 15px and caps the column at 860px, centered
(`viewer.css`). Headings are relative to that, so a top-level heading is 30px. On a projector that is a README page in
the middle of the screen. A deck cannot override it, since the page's content security policy blocks inline styles and
a deck runs no script. The viewer's own script runs in a separate content world, so the host can restyle the page.

Images fail for a different reason. A controller sends each slide with `show-markdown`. Inline Markdown has no file and
so no folder, and the page shows each image's alt text.

## Design Decisions (Settled)

### Two features in the viewer, not the presenter

Decision: the slide style and slide images are text viewer features, reached through its remote schema. The viewer
shows one slide's Markdown at a time. It does not split decks.

Rationale: the presenter passes content through and adds no rendering of its own, per UTERM-025. Splitting a deck is
the presenter's job, under UTERM-025's "Deck format rules". Other controllers that show Markdown gain the same
features.

### The Markdown page opts in

Decision: the text viewer's Markdown body opts in to controller keys, under UTERM-024 "Which panes take a controller's
keys". Its PDF and text bodies do not.

Rationale: the Markdown page takes no typed text. Its sanitizer allows no `input`, `textarea`, `select`, or
`contenteditable`, and the page runs no script. A PDF can hold form fields, and the find bar and contents sidebar take
their own keys, so none of those opt in.

### A slide style, not a zoom

Decision: the viewer gains a named slide style that a controller sends with each slide. The style sizes type to the
pane and drops the column cap. There is no arbitrary zoom or scale factor. The viewer does not save the style with the
layout. Restoring a presentation is the controller's job: a restored pane is inert, and a presenter that runs again
sets the style again. Amended 2026-11-16; see Decision Log.

Rationale: a slide needs type laid out for a slide, sized from the pane, with headings and lists in proportion. A zoom
factor scales the document style, so it keeps the column and leaves the controller guessing a number for each display.

### Slide images

Decision: `show-markdown` takes a base folder for a slide's relative images. The folder must lie inside the input
file's folder the user granted, under UTERM-032. The viewer reads each image under UTERM-015 M4's checks.

- Each image path is confined to the granted folder. A `..` or a symlink that leaves it is refused. This is stricter
  than the volume rule for documents the user opens, per UTERM-007's 2026-11-08 ADR candidate.
- A missing, refused, or out-of-scope image shows the same alt text, so the outcome tells the controller nothing about
  what exists. No reply about content sent with the slide style carries a landing anchor, since an image's size could
  change it. The viewer refuses `scroll` and `find` on that content, and any other reply about it omits its anchor.
- Remote, root-relative, and data-URI images stay refused, as for any Markdown the viewer shows.
- An image may name one page of a PDF inside the granted folder, as `talk.pdf#page=3`, per UTERM-029 "PDF page
  references". The page is drawn in the sandboxed document helper, never with PDFKit in the app, and every failure shows
  the same alt text. Amended 2026-11-17; see Decision Log.
- Once the grant ends, the viewer reads no further image. A slide that renders again, such as after WebKit's content
  process restarts or an undo restores it, shows alt text.

Rationale: the user chose a folder granted at run time, with the controller holding no file access, over sending image
bytes with each slide. The folder confinement follows UTERM-015's rule that a controller never borrows uniterm's macOS
privacy grants. The bug "Images in Markdown a script sends resolve anywhere on the volume" shows what the volume rule
allows for content a program supplied.

### Version skew

Decision: the viewer's remote schema is at 0.0 under UTERM-063 and does not bump. M1's style argument and M2's base
folder argument land in place, after UTERM-063 M2. A controller that sends an argument an older viewer does not know is
refused by name before any effect, under the strict decoders. An older controller reaching a newer viewer gets the
document style and no images, as today. UTERM-029's PDF page references land in place the same way. From schema 1.0 a
new optional argument is a minor bump. Amended 2026-11-27; see Decision Log.

### The style's wire shape

Decision: the slide style is an optional argument of `show-markdown`. The style belongs to that sent content, and a
controller sends it with every slide. It ends when the content is replaced. Reload and undo reopen bring it back with
the content.

Rationale: the style flows with the content it styles, and no pane state carries it from one call to the next. A
separate command that set pane state would fail silently. A user open mid-talk would end the style, and the
presenter's later slides would render in document style with no event to tell it. Such a command could also lay a
user-opened document out as one slide, and a second caller's Markdown would inherit the first controller's style.

### How the grant reaches the viewer

Decision: shared dispatch hands the viewer a slide-image capability with a `show-markdown` that carries a base folder.
The capability holds only the run's granted folder and a liveness check. It is never the caller's whole grant, and it
reaches only a command whose schema declares that it takes one. Liveness is the same authority check dispatch already
runs for that caller and pane, plus the folder still being in the run's grant. Run end, revoke, and the pane leaving
the run's control all end it. The viewer keeps the capability with the sent content and checks it at each image read.
A read in flight when it ends serves nothing. A caller that holds no folder grant has its base folder refused before
any effect.

Rationale: ADR-09 checks authority at the effect boundary, and queued work keeps no authority after its grant is
revoked. Checking the base folder once, at `show-markdown`, would let a Reload after revoke read every image again.
A per-read lookup of whoever controls the pane now would read one run's leftover slide under another run's grant. The
capability carries the sending caller's authority and nothing more. A capability narrowed to slide images keeps
UTERM-032's rule that the grant serves no other path read, even after other path commands land. Clipboard grants for a
run are already checked the same way, by a live closure at the point of use.

### The slide style's rules

How type sizes from the pane, such as from its height or its width, and the bounds on it. How a slide that overflows
the pane behaves. Shrinking to fit works with the keys, since the arrow keys step slides and cannot scroll. Whether the
user can switch a pane's style.

Decision, sizing: the slide style's base type size is the smaller of a fraction of the pane's width and a fraction of
its height, between a lower and an upper bound. The column cap goes, and spacing such as body, code block, and table
cell padding scales with the base size.

Decision, overflow: a slide that does not fit shrinks to fit. The viewer's script measures the rendered slide on both
axes, including code blocks and tables that scroll on their own, and lowers the base size until the slide fits. It
measures again when the pane resizes and when an image loads. Shrinking stops at a floor relative to the slide style's
own size, and never below the document style's size. The slide style bounds an image's height by the pane, so an image
shrinks with the slide. A slide that still overflows at the floor stays at the floor, scrolls by trackpad or mouse, and
shows a cue that content continues. The viewer reports nothing about overflow to the controller.

Decision, switching: only a controller sets the slide style. The user has no command to switch a pane's style. A pane
keeps the slide style after its controller ends, still showing the last slide. The style ends when the pane's content
is replaced, by a user open or by sent Markdown without the style.

Rationale: the smaller of the two fractions keeps type in proportion on a narrow pane beside the terminal and on a
short wide one. Height alone oversizes type in a narrow pane, and width alone oversizes it in a short wide one. A fixed
virtual canvas scaled to fit gives the same wrapping on every display, but it letterboxes the pane beside the terminal
and leaves half of it blank. Wrapping that varies with the display is the cost, and shrinking to fit absorbs it.

Shrinking fits a dense slide without a key that scrolls, so a presenter on a clicker reaches all of it. Clipping loses
content silently. Scrolling alone leaves a dense slide out of reach of the keys, and overlay scroll bars hide that more
exists. Reporting overflow to the controller was weighed and dropped. The viewer emits no events under UTERM-004. A
reply field would be stale: a load reply settles when the slide is placed, before its images load, and a resize changes
the fit later. No controller decision reads it.

A user switch serves no named need. After the controller ends, its keys go away, and the arrows scroll the slide again.
A toggle on a styled pane would also need a rule for who wins when the controller's next slide arrives. A toggle on any
pane would present a whole document as one slide, since the viewer does not split decks.

## Design Decisions (Open)

None.

## Risks

- **The viewer's command arguments are a published contract** — likelihood: high, impact: low. Mitigation: the schema is
  at 0.0, and an argument an older viewer does not know is refused by name. From schema 1.0 the major and minor rule
  covers new commands, and this proposal extends it to new optional arguments. Amended 2026-11-27; see Decision Log.
- **Images widen what a controller can make the viewer read** — likelihood: medium, impact: medium. Mitigation: reads are
  confined to the folder the user granted for that run, under UTERM-015's checks.
- **UTERM-024 is a draft, and the Markdown page's opt-in rests on its rule for which panes take a controller's keys** —
  likelihood: medium, impact: low. Mitigation: the opt-in is one decision that follows UTERM-024's final rule. The
  overflow rule does not rely on keyboard scrolling, since UTERM-024 puts the controller's keys before the view's.
- **Slide images wait on UTERM-015 M4, which is not built** — likelihood: medium, impact: medium. Mitigation: M1 needs
  nothing from UTERM-015, so the slide style ships on its own, and slides show alt text until M2 lands.
- **A scroll's landing could show the controller whether an image inside the grant exists** — likelihood: low, impact:
  medium. A loaded image changes the page height, and `scroll`, `find`, and `wait` report where the page landed. The
  script holds no file access under UTERM-032, so this would let it probe which image files lie under a broad grant.
  Mitigation: no reply about content sent with the slide style carries a landing anchor. The viewer refuses `scroll`
  and `find` there, and any other reply omits its anchor. A slide shrinks to fit, so a presenter needs neither.
- **UTERM-025's deck format rules are open, including how a slide's images are referenced** — likelihood: medium,
  impact: low. Mitigation: `show-markdown` takes a base folder per slide, so any rule that resolves images to a folder
  inside the grant fits without a change here.

## Milestones

### M1: Slide style

**Status:** NOT STARTED

- The Markdown body delivers controller keys, and the PDF and text bodies do not
- A controller sends a slide in the slide style, and a heading and a bullet list fill a projector-sized pane
- A user-opened document keeps the document style
- Padding and spacing scale with the slide's base size, and the slide has no column cap
- A slide too long for the pane shrinks until it fits, and a code line or table wider than the pane counts as overflow
- A slide still too long at the floor shows a cue that content continues, and scrolls by trackpad or mouse
- On a small pane, the floor never takes type below the document style's size
- Refitting settles with scroll bars always shown, and does not loop or stall during a split drag
- Resizing the pane, such as by dragging the split, refits the slide, and a fit measured for one slide never lands on the
  next
- A user open in a slide-styled pane shows the document style
- A slide shown again by Reload after WebKit's content process ends keeps the slide style
- A slide reopened by undo within the launch shows the slide style
- A `show-markdown` without the style argument shows the document style, even in a pane that showed a slide
- The viewer's schema stays 0.0, and an older viewer refuses the style argument by name before any effect
- A `show-markdown` style value other than the named slide style is refused before any effect
- The style rides with the sent text in the undo-only part, and never in the saved layout record
- A `scroll` or `find` on content sent with the slide style is refused before any effect, and no other reply or `wait`
  about that content carries a landing anchor
- Builds on UTERM-024 M2's keys

### M2: Slide images

**Status:** NOT STARTED

- A slide's relative image loads from a base folder inside the granted folder
- A base folder outside the granted folder is refused before anything is read
- An image reached by `..`, or by an absolute or relative symlink, outside the granted folder shows alt text, the same
  as a missing image
- Remote, root-relative, and data-URI images stay refused
- Builds on UTERM-032 M1's grant
- After the grant ends, a slide that renders again reads no image and shows alt text
- The image walk is confined to the granted folder, not only to its volume, and a protected location inside the grant,
  such as `~/Documents` under a granted `~`, serves no image unless the grant names it
- The base folder is compared with the grant without touching the filesystem, as APFS compares names. A base folder
  outside the grant is refused, and one inside it that does not exist shows alt text, the same as a missing image
- The image walk starts at the grant's canonical folder and walks the base folder's relative part, so a base folder
  that is a symlink leaving the grant serves no image
- An image taller than the pane is bounded by the pane, and a heading with a tall screenshot fits without reaching the
  floor
- Slide images load eagerly in the slide style, and an image that loads late refits the slide
- The viewer's schema stays 0.0, and an older viewer refuses the base folder argument by name before any effect
- The `show-markdown` load reply settles when the slide is placed, and never waits on image loads or on the fit
- A base folder from a caller that holds no folder grant is refused before any effect
- The slide-image capability reaches only a command whose schema declares it, and it serves no path outside slide
  images
- Liveness is checked before a read starts and again before it serves, so a read in flight when the grant ends serves
  nothing
- Revoking the run, ending it, or disconnecting the pane stops image reads, and a Reload after that shows alt text
- A Reload while the grant holds shows the slide's images again
- A slide reopened by undo during a live run shows alt text until the next slide arrives
- A base folder whose relative part holds `..`, or that matches the grant only after case folding on a case-sensitive
  volume, never walks outside the grant's canonical folder
- A file inside the grant that exists but does not decode as an image renders the same as a missing one
- An image path inside a protected location under the grant, such as `~/Documents` under `~`, renders the same whether
  or not the file exists, and the protected check runs before any lookup of that path

## Decision Log

- 2026-11-15: Filed as a required prerequisite of UTERM-025. The user chose readable projected text and slide images as
  required, after the design critic found the 15px column and the alt-text images.
- 2026-11-15: A named slide style, with no arbitrary zoom. The user chose it.
- 2026-11-15: Slide images load from a base folder inside the folder granted at run time. The user chose this. The
  option where the viewer opens the deck file by path was dropped, since it would put deck splitting in the viewer.
- 2026-11-16: the viewer does not save the slide style. The user's reason: the controller is in charge, so restoring
  is the controller's job. A restored pane is inert, and the controller sets the style again when it runs.
- 2026-11-16 (agent): the Markdown body opts in to controller keys, and the PDF and text bodies do not. UTERM-024 puts
  the opt-in in each applet's proposal.
- 2026-11-16: Review start: 2 milestones, 5 settled decisions, 2 risks, no `**Live after:**` lines or row gates;
  out of scope: deck splitting in the viewer, and an arbitrary zoom or scale factor. Reviewed at the commit "Settle and
  accept UTERM-032's run-time input file". The user asked for an autonomous review of the open question.
- 2026-11-16 (autonomous): the slide style sizes type from the smaller of a width fraction and a height fraction of the
  pane, bounded, with spacing in proportion. Height alone, width alone, and a fixed canvas scaled to fit were weighed.
- 2026-11-16 (autonomous): a slide that overflows shrinks to fit, down to a floor. Images are bounded by the pane. Past
  the floor the slide scrolls by pointer and shows a cue. Reporting overflow to the controller was dropped: the viewer
  emits no events, and a reply field would settle before images load.
- 2026-11-16 (autonomous): only a controller sets the slide style, with no user switch. The style ends when the user
  opens a file in the pane.
- 2026-11-16 (autonomous): the Summary names the Markdown page's opt-in to controller keys, and UTERM-024 joins the
  Dependencies. Three risks join: UTERM-024 is a draft, slide images wait on UTERM-015 M4, and a scrolling slide can
  show whether an image inside the grant exists. The last is mitigated, per the next entry.
- 2026-11-16 (autonomous): amended the slide images bullet. It said only that the outcome "tells the controller
  nothing about what exists". A scroll's landing could reflect an image's size, and the script holds no file access.
  No reply about content sent with the slide style now carries a landing anchor: the viewer refuses `scroll` and
  `find` there, and other replies omit the anchor. Narrowing the invariant and accepting the probe was weighed and
  dropped, since a mitigation exists. The widening from `scroll` alone to every landing came on the review's last
  critic pass and was not re-checked.
- 2026-11-16 (autonomous): amended M2's base folder check. It said a base folder "that does not exist inside the grant
  is refused the same way as one outside it". Knowing it does not exist touches the filesystem, and a refusal would
  tell the controller which folders exist. A missing base folder inside the grant now shows alt text.
- 2026-11-16 (autonomous): the slide style is an optional `show-markdown` argument that belongs to the sent content.
  Amended "A slide style, not a zoom", which said "a controller sets on its pane", and the switching decision, which
  said the style ends "when the user opens a file in the pane". A separate command setting pane state was weighed.
- 2026-11-16 (autonomous, addition): shared dispatch hands the viewer a slide-image capability with a base folder, and
  each image read checks its liveness. It adds a capability to the applet command contract, which every applet sees.
  Checking once at `show-markdown` and a per-read lookup by pane were weighed.
- 2026-11-16 (autonomous, addition): each milestone adds its own schema minor, 1.1 and 1.2. The shared schema rule,
  which every applet's remote schema follows, gains a new optional argument as a minor bump. Amended "Version skew",
  which said the style and the base folder "are a minor version".
- 2026-11-16: Review gate: kept all. The user chose the slide-image capability handed with the command, a schema minor
  per milestone with the shared rule extended, and no landing anchors on slide content.
- 2026-11-16: ADR candidate (cuts across the system): an applet receives a caller's authority only for the effect a
  command declares, and only while the grant is live. Declined: lifted to its invariant, it is ADR-09's effect-boundary
  check and its rule that queued work keeps no authority after revoke.
- 2026-11-16: ADR candidate (cuts across the system): a caller never uses what a later schema minor added, so a new
  optional argument bumps the minor. Declined: the shared schema rule and its doc comment record it, and no
  component can break it without the dispatcher's field check refusing.
- 2026-11-16: Accepted. The user chose it after the review gate. One minor at M2 and one release for both were weighed.
- 2026-11-17: Amended by UTERM-029. "Slide images" gains PDF page references drawn in the sandboxed document helper.
  "Version skew" gains schema 1.3 for them. Both decisions carried the marker "Amended 2026-11-16", which this one
  replaces. Their earlier text stands, and the new bullet and sentence are added.
- 2026-11-21: Scheduled as UTERM-030 M1-M2 in queue.md.
- 2026-11-27: From UTERM-063. The viewer's schema is at 0.0 and does not bump, so M1's style argument and M2's base
  folder argument land in place after UTERM-063 M2.
  - Amended "Version skew". It said "each milestone adds one minor version to the viewer's remote schema. M1's style
    argument is 1.1, and M2's base folder argument is 1.2", and "UTERM-029's PDF page references are 1.3".
  - Amended the Impacts lines for UTERM-007, UTERM-006, and UTERM-029, and the risk on a schema minor, which said "Each
    milestone advertises its own minor."
  - Amended the M1 check "The viewer advertises schema 1.1" and the M2 check "The viewer advertises schema 1.2". The
    checks now say an older viewer refuses the argument by name.

## References

- ADR-06: layout file versioning
- ADR-09: control authority requires authenticated identity and explicit scope
