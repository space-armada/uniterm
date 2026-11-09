# UTERM-007: Text Viewer Applet

**Status:** accepted
**Created:** 2026-10-31
**Updated:** 2026-11-08

## Dependencies

- UTERM-001
- UTERM-015: app-level opening and Cmd-O, and the type declarations its router reads. A later remote open command
  would use its path-reading power
- UTERM-006: M1 builds its document helper the way UTERM-006's image helper is built. UTERM-006 landed first, so M1
  built the shared helper code. Amended 2026-11-08; see Decision Log.
- UTERM-013, and UTERM-002's command registry: the find, contents, open, and reload commands are registry entries the
  viewer declares
- UTERM-004 M2 and M3: M5's remote commands need remote-controlled panes and the applet command hook
- UTERM-003 M2: M5's send-document check uses its send function

## Impacts

- UTERM-009 — "Control levels": the text viewer's restore message for inline content that had no file is the first
  answer to the restore rule UTERM-009 deferred for pipe input
- UTERM-006 — "RTF and Word use the system readers": both proposals run decoders uniterm does not own in sandboxed
  helpers of the same design
- UTERM-003 — "Control levels": "send a document or data to an applet" lands on the viewer's inline content command

## Summary

A read-only document viewer applet. It shows Markdown, RTF, Word documents, and PDFs.

## Motivation

READMEs, specs, and reports often need reading beside a terminal. A viewer pane renders them properly instead of as raw
text.

## Design Decisions (Settled)

### Read-only

The applet views documents. It does not edit them.

### PDFs use PDFKit

PDFs render with PDFKit's `PDFView`.

### RTF and Word use the system readers

RTF and Word documents load through `NSAttributedString`'s document readers and display in a text view.

The readers run in a sandboxed helper process, not in the app. The helper returns the attributed string through secure
coding, with embedded images already decoded to bitmaps, and the app shows it in its own text view. A helper crash or
hang ends that load, and the pane says so. The helper is built the way UTERM-006's image helper is: its own
executable with its own sandbox entitlements, a file descriptor the app opens and passes with each decode request, a
private decode-only protocol with a version handshake, and a footprint cap the app enforces. It is a separate
executable from the image helper, since the document readers need sandbox operations, such as the font service, that
the image decoders' sandbox denies. UTERM-006 landed first. This proposal's first milestone factored the framing, the
process supervision, and the liveness rules out of the image helper into code both helpers share. Amended 2026-11-08;
see Decision Log.

PDFs are the exception. `PDFView`'s selection, find, links, and accessibility work only on an in-process
`PDFDocument`, and no supported API remotes it. Rendering pages in a helper would mean rebuilding all of those over
raster tiles. So PDF parses in-process, as ADR-07 allows when isolation is not possible, and the hostile-document risk
states what bounds it.

### Markdown rendering

Original question: Foundation's Markdown parsing focuses on inline styles. It does not lay out full documents with
tables and code blocks. Render HTML in a `WKWebView`, use a native Swift Markdown renderer, or use QuickLook.

Decision: Markdown is parsed and laid out inside a `WKWebView`, by a pinned, bundled JavaScript Markdown parser such as
markdown-it. Raw HTML in the Markdown renders through a pinned sanitizer's allowlist. Nothing parses Markdown or HTML in
uniterm's own process. Amended 2026-11-08; see Decision Log.

- The parser runs as a `WKUserScript` in its own `WKContentWorld`. Page JavaScript is off
  (`allowsContentJavaScript = false`), so nothing in the document can run script, even if the parser emits markup it
  should have escaped. The one message handler is registered for the parser's world only.
- Raw HTML embedded in the Markdown passes through the parser. A pinned, bundled HTML sanitizer, such as DOMPurify,
  filters the parser's output in the same isolated world before insertion. Its allowlist matches GitHub's published
  README allowlist, minus anything that needs the network, so `<p align="center">`, `<h1 align>`, `<details>`,
  `<summary>`, `<img width>`, `<picture>`, `<kbd>`, `<sup>`, and in-page anchors render. It drops `script`, `style`,
  inline `style` attributes, `iframe`, `object`, `embed`, `form`, `input`, `audio`, `video`, `base`, `meta`, `link`,
  and event attributes.
- The scheme handler sends a Content-Security-Policy that allows images, the page's stylesheet, and the document's own
  text, each only from its own scheme, and denies scripts in the page, frames, forms, objects, and media. A
  `WKContentRuleList` also blocks every load outside the handler's scheme, whichever world started it, since WebKit may
  let loads from an isolated world skip the page's policy.
- The web view's light or dark appearance follows the uniterm theme, not the system, so `<picture>` sources that
  test `prefers-color-scheme` match the theme.
- Each pane's `WKWebView` uses its own non-persistent data store. It shares no cookies, cache, or storage with other
  panes or with UTERM-005's browser.
- The page, the document's text, and the images it references are served through a `WKURLSchemeHandler`, not
  `loadFileURL(_:allowingReadAccessTo:)`. The handler serves the document and image files the document links by relative
  path, through `src`, `srcset`, or `<source>`, resolved against the document's own folder, and nothing else. A
  root-relative or `file:` image path is refused. A path that would cross a mount point or leave
  the document's volume, such as one through `/net` or `/Volumes`, is refused before lookup, so no automount runs. No
  network load happens. A remote image shows its alt text.
- A same-document fragment link, such as `[Install](#install)`, scrolls to its target. Navigation leaves the view only
  for a user-activated link to `http`, `https`, or `mailto`, which opens in the default browser. Every other navigation
  is cancelled.
- Colors come from CSS variables generated from the `ThemePalette` the host pushes through `apply(_:)`.
- The page pushes its scroll position and headings to the host through the message handler. The host caches them, so
  `describe()` stays synchronous and never waits on the page.
- The parser and sanitizer assets are each pinned by version and content hash, and their license notices join
  `Licenses/` through the collect script.

Rationale: the Motivation asks for READMEs rendered properly, and many README headers are raw HTML, so showing that
HTML as text puts markup at the top of the page. A README comes from clones and downloads, so it is untrusted input. WebKit's content process is sandboxed and
out of process, so a parser bug, a hang, or a huge table ends or stalls that process, never the app (ADR-07, ADR-08).
swift-markdown wraps cmark-gfm, third-party C maintained outside the OS, with a heap-corruption CVE in table parsing.
Running it in-process is the exposure UTERM-009 rejected libxls for, and native `NSTextView` layout would also put an
attacker-sized table on the main thread. A sandboxed helper process running swift-markdown contains the same failures,
but rebuilds what WebKit already provides. An in-house Swift parser cannot corrupt memory, but a trap or a quadratic
input still ends or pins the app, and a hand-written GFM subset mis-renders real READMEs. QuickLook ships no rendered
Markdown on a stock system and cannot take theme colors. Foundation's full-syntax `AttributedString(markdown:)` parser
in a sandboxed helper, rendering into the native text view, was weighed on reopening. It contains failures and shares
find and selection with RTF and Word, but renders no raw HTML and may drop HTML blocks silently. Foundation in-process
lacks the ADR-07 exception PDF has, since a parse tree can cross a process boundary. A fully trusted mode
that passes all HTML was weighed too. Its trust mark would follow the path, so new content after a `git pull` would
render trusted, and with page JavaScript and the network off it adds only styles and iframes over the allowlist.
Left undone: remote images such as badges show their alt text, and authored inline styles are dropped.

### The applet contract

Original context and question: Context from UTERM-001, which shipped the applet contract. ADR-05 and ADR-06 cover its lifecycle and its description
versioning. An ADR for the rest of the contract is a candidate in UTERM-001's Decision Log. This proposal may reshape
it, so it is not written yet. Every applet implements:

- A view the pane hosts, a title, and status bar segments.
- `start`, `focus`, and a palette update.
- `detach`, `reattach`, and `close`. uniterm sends these lifecycle events, and each applet owns its response, per
  ADR-05. On detach an applet pauses audio, video, and alerts at once. uniterm keeps no closed applet alive. An applet
  that keeps work going after close owns its bound and a visible indicator.
- `isRunningSomething` and `runningLabels`. Closing a pane, a window, or the app asks first when an affected pane is
  running something, and the dialog names it.
- `describe()`, an inert description with a type and a per-type version. Undo and layout restore both rebuild the
  applet from it, in the same place. Undo is not a snapshot of running state. An applet that wants undo to bring back
  more saves it in its description. ADR-03 says restoring it never runs a program the user did not ask for. ADR-06
  says the applet owns its payload and its version. It upgrades its own older versions, and bumps the version on any
  change an older build cannot round-trip. A description this build cannot read is kept byte-for-byte.

For the text viewer: a description likely holds the file path and the scroll position. A read-only viewer likely never
counts as running something.

Decision: the text viewer needs no change to the applet contract or the factory. Its description holds a path, a
bookmark fallback, a start directory, and the view state, and never any of the file's contents. This follows UTERM-009's
applet contract decision.

- The payload holds the file's absolute path, a macOS bookmark of the file, the view state, and whether the contents
  sidebar is shown. It has its own version, per ADR-06.
- View state is a source anchor that survives reflow: for PDF, a page index and a point on the page; for RTF and Word,
  the character index at the top of the view; for Markdown, the source line of the top block, which the parser's token
  map gives, plus a fraction within that block.
- Restore opens the stored path when a regular file is there. It uses the bookmark only when the path is missing, and
  then says where it found the file. A file renamed away and replaced by a new one at the same path shows the new one.
- The bookmark is created at load, and remade when an open, a restore included, finds a different file than the
  bookmark names. Resolution runs in `start()`, off the main thread, without UI and without mounting volumes.
  `describe()` never touches the disk.
- Every description, the empty one included, holds the directory the pane started in. The factory passes it. An empty
  pane reports it as `currentDirectory`. With a file open, the pane reports the file's folder. The open panel always
  starts in `currentDirectory`, never in AppKit's remembered folder.
- Every format loads from a file read in full off the main thread: a PDF through `PDFDocument(data:)` from bytes the
  app reads, RTF and Word through `NSAttributedString`'s readers in the sandboxed helper, which reads the whole file
  from the descriptor the app opened, with the document type set from the file type, and Markdown through the scheme
  handler. A load is a snapshot. A later change to the file, such as pdflatex rewriting its output in place, reaches a
  view that is already showing only as a reload, which reads the whole file again. Amended 2026-11-08; see Decision
  Log.
- RTF and Word are decoded in the helper, and the decoded text's length and table cell count are checked against caps
  off the main thread, before the text view lays anything out. A document past a cap shows a message naming the limit.
  This is the bound ADR-08 asks for on the text view's main-thread layout.
- Files open inside the pane, by an Open... registry command with no key in the File menu and an empty-state button,
  or by dropping a file URL onto the pane. A pane shows one document. Opening another file replaces it, cancels any load
  still running, and starts at the top. The open panel selects one file. A drop of several files is refused with a
  message asking for one, and the pane keeps what it showed. App-level opening belongs to UTERM-015. Its File > Open on
  Cmd-O routes files here by type, and this Open... is the pane-local open it keeps. The viewer declares the types it
  opens, with a rank. Amended 2026-11-03; see Decision Log.
- A drawer of open documents beside the view, as Preview has, is an idea for later. This proposal does not commit to
  it. Building it needs its own proposal, since it changes what a pane and its description hold.
- A read-only viewer never counts as running something, and closing it never asks.

Rationale: the path is what the user named, so it wins while a file is there. The bookmark recovers a file that was
moved or renamed. Bookmark-first resolution follows the file ID, so an editor save that renames the old file to a
backup would restore the stale backup. Path-only loses a moved file and leaves the open panel on AppKit's hidden
remembered folder. Adding a file case to the factory and binding Cmd-O in one viewer would decide app-level opening from
one consumer, which UTERM-009 gave to a cross-applet proposal. A pixel scroll offset lands elsewhere after a width,
font, or reload change, while a source anchor does not. A PDF opened by URL reads pages lazily from the file, so an
in-place rewrite could feed CoreGraphics truncated bytes. Reading the whole file first bounds that, at the cost of
memory equal to the file's size.

### Live reload

Original question: whether the viewer reloads when the file changes on disk. Useful while editing a document in a
terminal.

Decision: the viewer always watches its file and reloads when it changes. There is no setting. A Reload registry
command, Cmd-R, re-reads the file on demand.

- The watch follows the stored path. It watches the file and its parent folder, so both a write in place and an
  editor's write-new-then-rename save are caught. The watch re-arms on the path after a rename or delete.
- Bursts of change coalesce. The last write is always loaded. A burst delivers once the file has been quiet for 0.15
  seconds, and a file rewritten without pause delivers at most once a second. A change that arrives while a load runs
  waits for it, and one more reload follows. Reload and opening another file end the running load instead. Amended
  2026-11-08; see Decision Log.
- A reload loads like a first load, off the main thread or in WebKit, and swaps in only when it succeeds. A failed load
  keeps the last good render and posts a warning to the status bar. A file that disappears keeps the last render. The
  status bar says once that it was moved or deleted, and a "Moved or deleted" warning segment shows until the file is
  back. The pane never follows the bookmark while live. When a file reappears at the path, the viewer reloads.
  Amended 2026-11-05; see Decision Log.
- A reload keeps the view state's source anchor, so the reader stays at the same place.
- While the pane is detached, changes collect and reload once at reattach. The watch stops at close.
- Reload covers volumes where file events never arrive.

Rationale: the Motivation is reading beside a terminal, often while editing the same file. Everyone who wants reload
wants it on, so a per-pane toggle would be a setting nobody needs, plus a payload field and a second code path. A manual
command alone leaves the view stale during exactly that loop. An FSEvents stream on the parent folder is equally
correct, but it receives every change in the tree below, such as build output beside a README at a repository root.
Following the bookmark live would switch to an editor's backup during a save, while the path briefly disappears.

### Search and navigation

Original question: find in document, and a table of contents from headings or PDF outlines.

Decision: find, plus a contents sidebar built only from structural outline data.

- Find (Cmd-F), Find Next (Cmd-G), and Find Previous (Cmd-Shift-G) are registry commands the viewer declares per
  UTERM-013, in Edit > Find. The viewer owns one find bar. It drives each format's engine: `PDFDocument`'s asynchronous
  find, a search of the text storage's string for RTF and Word, shown with selection and the find indicator, and
  a find in the parser's isolated world for Markdown, which returns highlight ranges and a count, since
  `WKWebView.find` offers no diacritic option and no count. The text view's built-in find bar and find panel are off.
  `NSTextFinder` is not used, since it takes its query only from its own bar or the system find pasteboard.
- The find query belongs to the pane. The viewer neither reads nor writes the system find pasteboard, so a search typed
  in another pane or app never appears here. The shared find bar offers what every engine supports: the query, next,
  previous, and whether there is a match. Match counts show where the engine gives one.
- A Show Contents registry command, with no key, toggles a contents sidebar. It lists the PDF outline, the Markdown
  headings the page pushes, or RTF and Word headings from `NSParagraphStyle.headerLevel` where the system reader sets
  it. Selecting an entry scrolls there. A document with no structural outline gets a disabled command and a sidebar that
  says there are no contents. Nothing is inferred from fonts or text.
- The sidebar's visibility is saved in the description.

Rationale: find is the main way through a long document, and every engine already exists. A table of contents built
from structure is exact wherever the format carries it. Inferring headings from font sizes lists bold body lines and
drops real headings, which is confident wrong navigation. A contents popup in the status bar would need clickable
segments, a contract change every applet shares, and works poorly for a spec with hundreds of headings. Left undone:
RTF and Word documents whose reader sets no heading level get no contents.

### Control levels

Original question: which UTERM-004 levels the viewer supports. The presentation example would send speaker notes here.

Decision: the viewer supports remote-controlled and disconnected access, both without an exec driver. Exec combinations
are refused before anything starts.

- Remote commands: scroll to an anchor (a page, a heading, or a source line), find text, reload, and show Markdown text
  sent inline. Each reply comes once the command's effect is done, so the reply to show or reload reports whether the
  content loaded. Per UTERM-004, remote callers receive no applet events, and the viewer emits none.
- There is no remote command to open a file path. A controller would otherwise make uniterm read any file uniterm can
  read, under uniterm's privacy grants, and learn from the reply whether a protected path exists. Neither caller needs
  it: notes arrive inline, and UTERM-003's send function sends content. UTERM-015 defines a scoped path-reading power
  under ADR-09 for every viewer. Remote opening waits on it, and adopting it later is an
  additive command.
- Replies carry anchors and load status only. They never carry document text, such as find matches or heading text,
  and never the path of a file the user opened.
- Per UTERM-004, every remote command names the applet type and the command schema version it was written for. The
  version is a major and a minor, as UTERM-006's schema is. A new command, or a new optional reply field, bumps the
  minor. A change in what a command means, or a removed command, bumps the major. The viewer accepts any version with
  its current major and a minor up to its own. Anything else is refused before any effect, so an old controller with a
  new app and a new controller with an old app both fail with an actionable error. The units on each side are external
  controllers and the app; UTERM-003's helper ships inside the app.
- Inline Markdown is the viewer's second source, beside a file. It renders like a file, with no relative resources:
  its relative images show their alt text. Showing it clears the stored path and stops the watch, and the pane reports
  its start directory as `currentDirectory`. It is never saved in the layout file. The payload records only that inline
  content was showing. Reopen within the launch brings the text back from the description's in-memory undo state. A
  relaunched pane says the content came from a program and was not restored.
- UTERM-003's "send a document or data to an applet" host function reaches the viewer through these same commands.

Rationale: the presentation program drives the slide, notes, and chart panes it owns through remote control, and
UTERM-003's send-data function goes through the same command validation. Inline notes let both work without writing
temporary files that a description would then point at. An exec driver has no caller here. It would make the pane own
a child process, contradicting the applet contract's rule that the viewer never counts as running something.
Deferring, as UTERM-009 deferred pipe input, was weighed. UTERM-009 deferred because UTERM-003 and UTERM-004 had not
settled, and both are now accepted, so its reason no longer holds. This departs from UTERM-009's deferral on purpose.
Leaves undone: an exec-driven viewer, until a caller needs one.

## Design Decisions (Open)

None.

## Risks

- **Word documents render imperfectly through the system reader** — likelihood: high, impact: low.
  Accepted: the viewer is for reading, not for faithful layout. Users needing exact layout can open the file in Word or
  Pages.
- **A hostile PDF corrupts or takes over the app** — likelihood: medium, impact: high. PDFKit and CoreGraphics parse
  PDFs from Downloads or email in uniterm's own process, with the App Sandbox off. A bug there can crash every terminal
  pane's shell with the app, or corrupt memory and run code with the user's privileges. uniterm owns no code there, so
  fuzzing can find such a bug but cannot fix it. This is ADR-07's stated exception: `PDFView` needs an in-process
  document, per "RTF and Word use the system readers". Mitigation: these are OS libraries that macOS updates patch,
  every read is capped and regular-file only, and M1 fuzzes PDF loading as shipped. RTF and Word parse in the sandboxed
  helper, and Markdown in WebKit's content process. **Revisit:** when M1's fuzzing finds a memory error or a hang the
  caps do not prevent, or an advisory in PDFKit or CoreGraphics is unpatched on a macOS version uniterm supports, file a
  proposal to render PDFs in the sandboxed helper and rebuild selection, find, links, and accessibility over its output.
- **The remote command schema becomes a contract external programs depend on** — likelihood: high, impact: medium.
  Presentation programs and scripts will call it. Mitigation: the schema is versioned from its first release, every
  command names its version, and additive changes bump only the minor, which older controllers keep working with, per
  "Control levels".
- **Many large documents exhaust memory** — likelihood: medium, impact: high. Each file is read whole, and PDFKit's
  decoded pages use more memory than the file. A relaunch restoring several large PDFs could get uniterm killed along
  with its terminals. The evidence does not settle the likelihood, so it is rated medium. Mitigation: the per-file cap
  on bytes read, and the decoded caps for RTF and Word. Accepted beyond that: unlike UTERM-009's row store, the viewer
  holds one document per pane, and a shared budget would have to predict PDFKit's own page cache.
- **UTERM-015 reshapes opening** — likelihood: low, impact: low. It is accepted. It keeps the viewer's Open... and drops,
  gives Cmd-O to the window's File > Open, and asks the viewer to declare its types. Mitigation: M1 declares the types
  and binds no File > Open key.
- **The bundled JavaScript parser and sanitizer fall behind** — likelihood: low, impact: medium. They are pinned
  outside SwiftPM, so no tool flags their updates. A parser bug stays inside WebKit's sandboxed content process, page
  JavaScript is off, and a sanitizer miss still meets the Content-Security-Policy. Mitigation: each pin records the
  version and hash, and the license collect script lists both, so a bump is a reviewed change.
- **The description is stored data** — the payload format is read by every later build. The design defuses the one-way
  door: the payload carries its own version per ADR-06, and an unreadable description is kept, not dropped.

## Milestones

### M1: PDF and RTF

**Status:** DONE

- A pane can run the text viewer and open a PDF
- The viewer opens RTF and Word documents
- Pages scroll and text can be selected and copied
- The viewer declares the content types it opens, with a rank, for UTERM-015's router
- A file opens from the Open... command, the empty-state button, or a drop. Dropping a file on a PDF or text view
  opens it in the pane, and the viewer binds no File > Open key
- The launcher offers the text viewer, and restore picks it by description type. An unknown type still becomes a
  placeholder pane
- Reopen and relaunch bring back the file at its view state, and an empty pane reopens empty in its start directory
- A file moved or renamed after the save is found through its bookmark, and the pane says where. A new file at the
  stored path wins over the bookmark, and the bookmark is then remade for it
- Opening a file into a pane that shows one replaces it and cancels any load still running. A drop of several files is
  refused with a message asking for one file, and the pane keeps what it showed
- The open panel starts in the pane's `currentDirectory`, never in the panel's remembered one
- A restored file behind macOS privacy protection, such as Downloads, shows a permission message, and `start()` raises
  no prompt
- A layout save never touches the disk to describe a pane, and an unchanged pane describes itself the same way twice
- A PDF rewritten in place while showing keeps rendering the loaded document until a reload succeeds and swaps in.
  Amended 2026-11-08; see Decision Log.
- RTF and Word load with the document type set from the file type, so a file is never read as HTML
- A file too large to load shows a message naming its size, never a freeze or a crash
- Every read, reloads included, opens the file and accepts it only when `fstat` shows a regular file after symlinks
  are followed, and counts the bytes actually read against the cap. A symlink to `/dev/zero` or a FIFO shows a message
- An RTF or Word document past the decoded length or table cell cap shows a message, and never lays out on the main
  thread first. Embedded images are capped by count and pixel size and never decode on the main thread at draw time
- A `.docx` whose entries inflate far past the byte cap ends at the helper's memory limit, never in the app
- A decode that never finishes leaves the pane usable, and a reload never starts a second decode while one runs
- One documented rule picks the format from the file type and extension, `README` and `.markdown` included, and an
  unsupported type shows a message naming it
- While the bookmark is still resolving, `describe()` returns the restored payload unchanged. Once the bookmark finds a
  moved file, the stored path becomes the new one
- A fuzzing run with malformed PDF input, through PDF loading as shipped and under a memory-error detector, records
  every crash and hang it finds
- RTF, `.doc`, and `.docx` parse only in the sandboxed helper. A malformed file that crashes or hangs the helper leaves
  the app and the pane running, and the pane shows a message
- The app decodes the helper's reply only through secure coding of the expected classes, and embedded images arrive as
  bitmaps within the pixel caps
- The document helper is its own executable, built the way UTERM-006's image helper is, sharing its framing, process
  supervision, and liveness rules, with a protocol version handshake of its own. The sandbox operations the readers
  need are recorded, and the image helper's sandbox stays as narrow as before. Amended 2026-11-08; see Decision Log.
- The document helper cannot open a file by path or make a network connection. It reads only the descriptor the app
  passes
- Embedded images cross as raw pixel buffers in one fixed format, outside the archive, and the app builds images from
  them with no codec. The allowed classes leave out `NSImage`, `NSBitmapImageRep`, and `NSFileWrapper`
- The app caps the reply's bytes before decoding it, then applies the decoded length, table cell, image count, and
  pixel caps itself, relying on no check in the helper. Attributes off an allowlist are dropped in the helper
- Opening another file, a superseded reload, or closing the pane ends the helper's decode, killing the helper if it
  has to. No helper outlives its pane, a PDF or Markdown pane starts none, and undo-reopen starts a fresh one
- The app enforces the helper's memory limit and kills it past the limit, which is what bounds `.docx` inflation
- A link in an RTF, Word, or PDF document opens only `http`, `https`, or `mailto`

**As built:**

- Shared helper code now lives in two targets that the image viewer was rebased onto.
  `HelperWire` holds the framed socket with descriptor passing, big-endian field coding, and page buffers.
  `HelperHost` holds the helper location, spawn and reap, footprint reads, the end reasons, and a pure liveness state
  machine that tells a hung helper from a slow one. Each helper keeps its own protocol, handshake, and entitlements.
  The image viewer's tests changed in imports and in the reader-start call's signature only, and no assertion changed.
  `SourceAccess` gained `RegularFile`, the one open, `fstat`, and counted capped read. The table loader, the GeoJSON
  reader, and the image opener use it.
- The document helper is a native Xcode tool target with sandbox-only entitlements, embedded in `Contents/Helpers`, plus
  a SwiftPM twin for the package tests. The tests prove crash, stop, spin, over-footprint, supersede, and close against
  the twin with faults read from a marker at the start of a file. Codesigning the built debug helper showed
  `com.apple.security.app-sandbox` and `get-task-allow`, and `check-sandbox-off.sh` passed on the built app for both
  helpers.
- The sandbox operations the readers need are none beyond the default App Sandbox profile on this macOS. The
  coordinator ran `make test-helper-sandbox` outside the agent sandbox: 6 tests, 0 failures, including the shipped
  helper's denied file open and network connection, and RTF, `.doc`, `.docx`, link, and table samples decoding under the
  sandbox. The unified log for that window showed "AppSandbox request successful" for each document helper spawn and no
  deny lines for the reader decodes. The only denials were the probe's intended file read and outbound connection. A
  plain `make test-package` skips the shipped-helper tests, since they need the built app's helper.
  `scripts/check-sandbox-off.sh` passed on the built app for both helpers.
- On the macOS this was built on, the RTF, Word 97, and Word XML readers returned no attachment for a picture in any
  sample, hand-built `.docx` included. The helper's raster path, the placeholder archive, and the app's rebuild from raw
  pixels are proved with attachments built in code. No reader-made picture was run through it.
- Each decode starts its own helper process and ends it when the decode ends. No process outlives a load, a pane, or a
  superseding open, and a PDF pane starts none. An undo-reopen therefore starts a fresh one.
- The text view uses TextKit 1, since only that layout draws `NSTextTable`. The document page stays white with the
  document's own colors, and the theme colors the surround and the messages.
- Markdown shows the unsupported-type message, and the viewer declares no Markdown type yet. The format rule already
  maps `README` and the Markdown extensions to Markdown.
- A PDF URL link opens through `PDFViewDelegate`'s link hook. The SDK header says a delegate that implements it handles
  the click, and the default `NSWorkspace` open does not run. The PDF view also refuses every action that is not page
  navigation or a link to a safe scheme: a remote go-to, a form reset, a print command, and a URL with another
  scheme. Whether PDFKit's own click path calls the view's `perform` method for each of these was not driven with a
  real click, so the filter is proved at the method, not through a click.
- Fuzzing: `PDFFuzzTests` loads mutated PDFs through the shipped path, and `DocumentWireFuzzTests` mutates the helper
  protocol. Both ran at 500 inputs in `make fuzz` and at 20,000 inputs each under the address sanitizer. The run found
  no crash, hang, or sanitizer report. The corpus is two generated PDFs and one hand-written one, so it says little
  about a PDF that resembles none of them.
- A restored file behind macOS privacy protection reads like the data viewer's: the open fails with a permission
  message and `start()` shows no prompt of uniterm's own. The system's own consent dialog for a protected folder was
  not exercised.
- Caps: see Decision Log.

### M2: Markdown

**Status:** DONE

- The viewer renders Markdown headings, lists, code blocks, tables, and links
- Rendered Markdown uses the current theme's colors
- A document whose Markdown carries `<script>`, event-handler attributes, or `<meta http-equiv="refresh">` runs nothing
  and navigates nowhere
- Raw HTML on GitHub's README allowlist renders, such as a centered header, `<details>`, and `<kbd>`, and every tag off
  the allowlist is dropped. The allowlist's source and version are recorded with the sanitizer pin
- With the sanitizer bypassed in a test build, markup inserted from the parser's world, including a remote `<img src>`
  and a remote `srcset`, makes no network request, and scripts, frames, forms, and media stay blocked
- Theme colors apply with the policy in force
- An in-page anchor link, Markdown or authored HTML, scrolls to its target
- A document whose top block is raw HTML reopens at the same place, and data attributes written in the document cannot
  spoof a source anchor
- On a dark-mode Mac with a light uniterm theme, a `<picture>` that tests `prefers-color-scheme` shows its light source
- `srcset` and `<source>` images follow the same rules as `src`, and a root-relative or `file:` image path loads
  nothing
- A relative image link, `../` paths included, shows the image. A link to a non-image file or a remote URL loads
  nothing
- A link opens in the default browser only when clicked, and only for `http`, `https`, or `mailto`
- A 20 MB Markdown file opens without stalling the main thread
- A layout save taken after the page's scroll report arrives, one message after the scroll, reopens on that scroll
  position. Amended 2026-11-08; see Decision Log.
- The parser and sanitizer assets are pinned by version and hash, and their license notices are collected
- Dropping a file on rendered Markdown opens it in the pane
- An image path through `/net`, `/Volumes`, or any other mount point, directly or through a symlink in any component,
  is refused without triggering a mount
- An image that is a symlink to a device or a FIFO, or larger than the cap, loads nothing
- When WebKit's content process ends, the pane shows a message and reloads on Reload
- Reload fetches images again, never WebKit's cached copies
- Two Markdown panes, and the browser applet, share no web storage or cache
- After reopen at a different pane width, the same heading or paragraph is at the top

**As built:**

- The page is three user scripts in one named content world, the pinned markdown-it and DOMPurify and the viewer's own
  script, with page JavaScript off. The one message handler is registered for that world. A WebKit content process
  runs all of it. A probe confirmed that user scripts in a world still run with `allowsContentJavaScript = false`, and
  that the page's own scripts do not.
- Each Markdown pane builds its web view when the first Markdown file opens, and removes it when the pane shows
  anything else. A PDF or RTF pane starts no web content process. The data store is non-persistent, so no pane shares
  cookies, cache, or storage with another pane or with the browser.
- The scheme handler serves four routes: the page, its stylesheet, the document's text, and `image`. The world's
  script rewrites each plain relative `src`, `srcset`, and `<source>` reference to an `image` request that carries the
  path whole in one query value, so a `..` reaches the handler intact. A page URL would have collapsed it. Every other
  image reference loses its attribute and shows alt text. The handler allows only image types by extension, and
  answers 404 with no body for anything else.
- Relative image files open through a new walk in `SourceAccess`. It goes one component at a time from the document's
  folder, refuses any directory or file whose device differs from the folder's, follows links by splicing their target
  into the walk, and refuses `net`, `home`, `Volumes`, and `Network` by name at the root before looking them up. The
  system and Data volumes share one device on macOS, so the walk treats them as one volume. A path that reaches `/dev`,
  an automount, or another volume's mount point stops at the mount. The final file is judged from its descriptor by
  the same regular-file check as every other read, so a link to a device or a pipe loads nothing.
- Raw HTML runs through DOMPurify with GitHub's published README allowlist as its configuration. The pin file records
  the allowlist's source and commit. Three narrowings follow the proposal's "minus anything that needs the network": the
  `longdesc` attribute is dropped, `srcset` is kept only on `<source>`, and links keep only `http`, `https`, and
  `mailto`, where the published list also keeps `ftp` and others. The form attributes on the list stay and do
  nothing, since no form element is allowed.
- The source anchor comes from the parser's token map, kept in the world's state against each block's elements. The page
  never reads a DOM attribute to learn a line. A block of raw HTML reports the line it starts at, and restores within
  itself by fraction. The page pushes the anchor from its scroll handler, and `describe()` returns the last one pushed.
  A save taken before that message arrives sees the position before the scroll. Every page message carries the
  document's generation, and the host drops a message from an earlier document.
- A debug build can swap the sanitizer for a pass-through that builds executable markup. The tests use it to show that
  the Content-Security-Policy and the rule list each keep every request off the network without the other, and that
  the sanitizer is not what holds the line. Release builds contain no such switch. WebKit's own fragment parser drops
  script elements and handlers while page script is off, so the test also appends hand-built scripts.
- Reload is a method on the pane with no key and no registry command. The message that shows when WebKit's content
  process ends carries a Reload button, and the pane keeps its last position in the description meanwhile. Cmd-R
  belongs to the next milestone.
- Raw HTML that opens an element in one block and closes it in a later one, as `<details>` does around Markdown, would
  strand its body outside the element if each block were sanitized alone. A block that leaves an element open starts a
  unit, and the unit takes the following blocks until the element closes, up to 400 blocks, then sanitizes as one. A
  unit counts as one block for scroll anchors, so a long `<details>` restores by fraction within it. Headings inside it
  carry the unit's first line.
- The `.md` extension types as another app's `com.unknown.md` on the machine this was built on. That type does not
  conform to Markdown, and the router has no extension fallback, so such a file would be refused. `Info.plist` now
  imports `net.daringfireball.markdown` with the Markdown extensions, and a router test shows why the type matters.
  Whether Launch Services prefers that import over another app's claim on a given machine is not provable in a test.
  The built app was not registered to check it.
- The page renders in slices and yields between them. WebKit lays out everything inserted so far while the page is idle,
  and fixed 30 ms slices made that cost quadratic. Each slice is now three times the last yield's duration. A 20 MB file
  went from 87 s to 4 s, and the host's longest main-thread gap stayed under 30 ms. See Decision Log.
- Not done here: find, the contents sidebar, and the rule for a `<details>` match are M4. Live reload is M3. Task-list
  checkboxes render as text, since `input` is off the allowlist. A drop on rendered Markdown is covered by the web
  view registering for no drag types and the pane view receiving the drop, not by a real drag.
- The viewer now declares the Markdown type and lists it in the open panel. M1's note that Markdown shows the
  unsupported-type message no longer holds.

### M3: Live reload

**Status:** DONE

- Saving the file in place, or by an editor's write-new-then-rename save, reloads the pane at the same place
- A burst of writes, such as `cmd > file`, ends with the last write shown, and a continuously rewritten file reloads
  at a bounded rate
- Changes to other files in the folder reload nothing
- A file that fails to load keeps the last good render and posts a status bar warning. A moved or deleted file keeps
  its render, posts one warning, and shows a warning segment until it reappears. Amended 2026-11-05; see Decision Log.
- After the file, or its parent folder, is deleted and recreated, the file reloads when it reappears at the path
- After restore finds a moved file through its bookmark, the watch follows the updated path
- A detached pane reloads once at reattach, and close stops the watch
- Reload, Cmd-R, re-reads the file

**As built:**

- The watcher is a new small target, `FileWatching`, that the map viewer and the text viewer share. The map viewer's
  own watcher moved into it. The map keeps its policy: the file alone, every event at once, and ten looks for a gone
  file, half a second apart. Its tests changed in an import and a callback signature only.
- The text viewer's policy watches the file and its folder. A folder event counts only when it changes what the path
  holds, which a signature of device, inode, size, and write time decides, so a neighbor's change delivers nothing. A
  deleted or renamed folder, or file, re-arms both watches. When the folder is gone the watcher looks again every half
  second, and every five seconds after ten looks, until the pane closes.
- Coalescing runs on an injected clock, so the burst, ceiling, and last-write rules test without waiting. The
  filesystem tests use real events with 50 ms windows.
- A reload swaps in only on success and keeps the anchor read when the reload began, not when it swaps. A reader who
  scrolls during a slow RTF decode lands where they were at the start. A failed reload posts its warning once for the
  load, and a later reload posts again. A Cmd-R while the file is still gone is a new load. It posts the moved or
  deleted warning again, and no failed-load warning beside it.
- The watch starts once a load finds the file, before the read, and the load waits for the watch to be in place. A
  first load that finds the file and cannot read it keeps the watch, so fixing the file reloads it. A path that cannot
  be found starts no watch. Cmd-R reads the stored path, and a success starts the watch.
- The Moved or deleted segment clears whenever the watch sees the file again, even when the reload then fails. The
  failed-load warning shows beside the kept render.
- Every stat and open of the watched path runs on the watcher's own queue, never the main thread, so a stalled network
  mount or an automount blocks only that queue. A rename of a folder above the watched folder is not detected, since
  the folder's descriptor follows the moved folder. Cmd-R covers it.
- A watcher stops its sources and timers when it is released, as well as on `stop()`. The text viewer test harness
  defaults to a silent watch, so a test that leaves a pane open cannot reload or poll after its folder is deleted. Only
  the live reload tests and one Markdown reload test ask for a live watch.
- A reload reads the stored path alone. The bookmark is remade for the file that opens and never followed.
- Opening a named pipe hung the main thread, because opening a pipe for reading waits for a writer. An existing
  Markdown test, whose pane is pointed at a pipe, found it. The watch now opens with `O_NONBLOCK`, and a watcher test
  pins it.
- Not run here: the two new UI tests, which need a GUI session. They build.
- `MarkdownAppletTests` and `MarkdownViewTests` fail in the package's full run on this machine's agent session, on the
  code before this milestone as well, and pass when run alone. The full run skipped them.
- A PDF shown with no anchor landed about 90 points down its first page whenever the view already had a size when the
  document arrived, which a restored pane's launch does and a pane sized later does not. PDFKit picks the scroll
  position, and it differs with timing. The pane now scrolls the document view to its top once it has a size, so a
  restore with no anchor, a fresh open, and a pane sized later all start at the same place, with the page's top margin
  showing. An anchored restore and a reload already put the stored point back where it was saved, and a test pins
  both. The first screenshot of this milestone's UI run showed the shifted page.
- Cmd-R is also the browser's reload key. Keys apply per applet while its pane has focus, so the two do not collide.

### M4: Find and contents

**Status:** NOT STARTED

- Find, Find Next, Find Previous, Show Contents, Open..., and Reload are registry commands the viewer declares, and none
  of their keys is a reserved window key
- The Find items sit in Edit > Find. The milestone that lands first, this one or UTERM-009 M3, adds the Edit menu home
- Find looks and behaves the same in PDF, RTF and Word, and Markdown, including Markdown with page JavaScript off.
  It offers the query, next, previous, and whether there is a match, plus a match count where the engine gives one
- A search typed in another pane or app never appears in the viewer's find bar, and the viewer's query never changes
  the system find pasteboard. Use Selection for Find sets the pane's query only
- The contents sidebar lists the PDF outline, Markdown headings, and RTF and Word headings where the reader sets a
  heading level. Selecting an entry scrolls there
- A document with no outline disables Show Contents. A huge or cyclic outline is capped, and the sidebar says it was cut
- The sidebar's visibility survives reopen and relaunch
- RTF and Word heading levels survive the trip through the helper, so the sidebar lists them
- Searching an RTF or Word document at the decoded cap never blocks the main thread
- A reload while a search runs or results show discards the old matches
- Use Selection for Find, Cmd-E, and the find menu items reach the viewer's commands, never a view's built-in find
- Case and diacritic matching is the same in every format
- A find query, from the find bar or a remote command, reaches the parser's world as a call argument, so quotes or
  `</script>` search literally
- Markdown find matches text that spans inline elements, and one documented rule says whether a match inside a closed
  `<details>` is revealed or skipped

### M5: Remote control

**Status:** NOT STARTED

- The viewer declares remote-controlled and disconnected access without an exec driver, and an exec combination is
  refused before launch
- Scroll to anchor, find, reload, and show inline Markdown work through UTERM-004's remote host call, and the reply to
  show or reload reports whether the content loaded. The viewer emits no events. No remote command opens a file path
- A controller written for schema 1.0 keeps working against a viewer on 1.1. A command naming another major, or a minor
  newer than the viewer's, is refused before any effect
- Scroll or find sent before a load finishes waits for the load or returns a structured error
- Replies carry no document text and no path the user opened
- Inline content that is not Markdown, or larger than one frame, returns a structured error
- While inline content shows, `currentDirectory` is the start directory
- Reopen within the launch brings back inline notes from the description's undo-only part, and an unchanged pane
  still describes itself the same way twice without re-encoding them on the main thread
- Showing inline content stops the watch, and a superseded load is discarded, so a late file reload never replaces the
  notes
- Inline content loads no relative resources
- After relaunch, a pane that showed inline content shows a not-restored message, and an older build keeps its
  description
- UTERM-003's send-document function shows content in the viewer
- A pane opened by a controller creates its own non-persistent web data store, like any other pane

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-11-01: Added "The applet contract" with context from UTERM-001's implementation.
- 2026-11-03: Review start: 2 milestones, 3 settled decisions, 1 risk, no `**Live after:**` lines or row gates; no
  out-of-scope statements; proposal at commit 42057e4. The user asked for a design review of the open questions, in
  autonomous mode, with UTERM-009's cross-applet decisions as precedent and any departure from them flagged.
- 2026-11-03: Markdown rendering: a pinned, bundled JS parser in an isolated content world inside a `WKWebView`, with
  page JavaScript off, a scheme handler serving only the document and its relative images, and no network. Converged in
  one pass. (autonomous, addition: a bundled third-party JS asset, pinned and license-collected outside SwiftPM)
- 2026-11-03: The applet contract: no contract change, following UTERM-009. The description holds a path with a
  bookmark fallback, an explicit start directory, a reflow-proof source anchor, and the sidebar's visibility, never file
  contents. Every format loads from bytes read in full. M1 waits on the cross-applet file-opening proposal UTERM-009
  committed to. Converged in one pass. (autonomous)
- 2026-11-03: Live reload: always on with no setting, watching the path and its parent folder, keeping the last good
  render, plus a Reload command on Cmd-R. Converged in one pass. (autonomous)
- 2026-11-03: Search and navigation: registry Find commands with one find bar over each format's engine, and a contents
  sidebar from structural outlines only. Converged in one pass. (autonomous)
- 2026-11-03: Control levels: remote-controlled and disconnected access without an exec driver, with a versioned
  command schema including inline Markdown that is never saved. Converged in one pass after the critic added the
  no-exec option. Departs from UTERM-009's deferral of pipe input, since UTERM-003 and UTERM-004 are now accepted.
  (autonomous, addition: a published remote command and event contract, a second content source, and M5)
- 2026-11-03: Coherence review. Amended "Control levels": dropped the remote open-path command, since it would let a
  controller read any file under uniterm's privacy grants and probe whether protected paths exist; added the schema's
  skew rules; inline notes come back on reopen from in-memory undo state. Bounded RTF and Word layout with decoded caps
  checked off the main thread. Image paths never cross a mount point. Routed regular-file and byte-count checks,
  bookmark path updates, a dead WebKit content process, find feature parity, and event coalescing to milestone checks.
  (autonomous)
- 2026-11-03: Hidden state, raised per CLAUDE.md "Applet Attributes": the find query belongs to the pane instead of the
  system find pasteboard, and each Markdown pane uses its own non-persistent web data store instead of WebKit's shared
  default. (autonomous)
- 2026-11-03: Risk review. Added risks for in-process PDF and Word parsing, with fuzzing in M1 and a revisit hook for
  a sandboxed helper; the published remote schema; memory across many large documents, mitigated by per-file caps and
  accepted beyond them; the unfiled file-opening proposal; and the bundled parser's upkeep. Noted the description's
  one-way door. (autonomous)
- 2026-11-03: Re-check. Text-view find searches the text storage directly instead of through `NSTextFinder`, which
  reads its query only from its own bar or the find pasteboard. The remote schema version is declared once per binding
  in the handshake, so events before a controller's first command have a version. (autonomous)
- 2026-11-03: Final re-check. The listener handshake carries no applet schema version, so the version moved into a
  bind command, the first a controller sends a viewer pane; no event goes out before it. This fix was made after the
  proposal loop's third pass and was not re-checked. (autonomous)
- 2026-11-03: ADR candidate (cuts across the system): untrusted documents are parsed in-process only by OS-maintained
  libraries, and a third-party parser runs out of process, as Markdown does in WebKit. Declined on 2026-11-03: the user
  chose UTERM-006's rule instead, that decoders uniterm does not own run in a sandboxed helper. ADR-07 already states
  it, and UTERM-006 declined the same candidate for that reason.
- 2026-11-03: ADR candidate (cuts across the system): control over a pane never lends a controller uniterm's own access
  to files. Waits on the cross-applet file-opening proposal UTERM-009 committed to, which defines any scoped
  path-reading power under ADR-09.
- 2026-11-03: ADR candidate (cuts across the system): applet state never comes from shared system state such as the
  find pasteboard, AppKit's remembered folder, or WebKit's default data store. Declined: CLAUDE.md "Applet Attributes"
  already states it.
- 2026-11-03: Hidden state, chosen by the user at the review gate per CLAUDE.md "Applet Attributes": the find query
  belongs to the pane, not the system find pasteboard, and each Markdown pane uses its own non-persistent web data store.
- 2026-11-03: Review gate: reopened Markdown rendering, in converge mode. The user asked to weigh HTML support in
  WebKit (raw HTML disabled, a sanitized subset, or a fully trusted mode with all HTML) and Foundation's full-syntax
  Markdown parsing into a native text view. If judging finds no clear winner, both may be built for a user-driven
  comparison. The other gate items wait until this settles.
- 2026-11-03: Markdown rendering, reopened: raw HTML renders through a pinned sanitizer's GitHub-aligned allowlist,
  with a Content-Security-Policy backstop and the web view's appearance taken from the theme. Markdown find runs in the
  parser's world. Before, raw HTML was disabled and showed as text. Converged in one pass; chosen by the user over
  Foundation full-syntax parsing in a helper, a trust-level mode, and building both for comparison. (addition: a second
  bundled third-party JS asset, the sanitizer)
- 2026-11-03: Re-check of the Markdown amendment converged. Added a content rule list that blocks every load outside
  the viewer's scheme, since loads started from an isolated world may skip the page's policy, and let in-page anchor
  links scroll. (autonomous)
- 2026-11-03: Followed two UTERM-009 amendments the user made during the UTERM-006 review. The bookmark is remade when
  an open finds a different file than it names, so a restore never follows it to a rotated-away file. A pane shows one
  document, opening another replaces it, and a drop of several files is refused with a message asking for one. Noted a
  Preview-style document drawer as an idea that needs its own proposal. (autonomous)
- 2026-11-03: Amended "RTF and Word use the system readers", by the user's choice: the readers run in UTERM-006's
  sandboxed helper and return a secure-coded attributed string. Before, they ran in the app, as UTERM-009's readers do.
  UTERM-009's caps and fuzzing protect code uniterm owns, while uniterm owns no code in these importers. PDF stays
  in-process as ADR-07's stated exception, since `PDFView` needs an in-process document. Rewrote the hostile-document
  risk for PDF only. (addition: a dependency on UTERM-006's helper and sandbox profile)
- 2026-11-03: Re-check of the helper split converged. The helper is shared with UTERM-006, but the document readers'
  sandbox operations never widen the image decoders' sandbox. Routed checks for codec-free image transfer, app-side
  caps, helper lifecycle, the memory limit, and link schemes to M1. (autonomous)
- 2026-11-03: Review gate: kept control levels, bind-command versioning, and the memory risk's acceptance. The user
  reopened nothing else.
- 2026-11-03: Accepted by the user after the review.
- 2026-11-03: Amended "Control levels" and "RTF and Word use the system readers" while rebasing onto UTERM-004,
  UTERM-006, and UTERM-008, accepted concurrently. UTERM-004 now has every remote command name its applet type and
  schema version, and gives remote callers no events. So the viewer's bind command and its two events are gone, and the
  show and reload replies report whether content loaded. The schema version is a major and a minor, as UTERM-006's is.
  UTERM-006's image helper is decode-only with a narrow sandbox, so the document readers get their own helper of the
  same design instead of sharing it. Remote file opening waits on the scoped path-reading power the cross-applet
  file-opening proposal defines. Before, the viewer had a bind command, events, an integer version, and a helper shared
  with UTERM-006. (autonomous)
- 2026-11-03: Amended "The applet contract" for UTERM-015, the cross-applet file-opening proposal UTERM-009 committed
  to. It said app-level opening and any File > Open key waited on that proposal, and that M1 started only after it was
  filed. UTERM-015 is now accepted. Its File > Open owns Cmd-O and routes files here by type, the viewer's Open... is
  its pane-local open, and the viewer declares the types it opens. M1's gate on the filing became a check that the
  viewer declares its types. Dependencies, "Control levels", and the opening risk now name UTERM-015.
- 2026-11-03: Scheduled as UTERM-007 M1-M4 and UTERM-007 M5 in queue.md.
- 2026-11-05: Live reload notices go to the status bar, after a status bar audit. The render stays on screen in both
  cases, so the pane has no need to speak. The text said a failed load gets "a status message" and a moved or deleted
  file is told by "the pane". A failed load now posts a warning. A moved or deleted file posts one warning and shows a
  "Moved or deleted" warning segment until the file is back. This follows the rule the user set for the map and data
  viewers: a notice about content still shown posts once, with a segment while it holds.
- 2026-11-08: Amended "RTF and Word use the system readers", "The applet contract", and M1's helper bullet. The text
  said the helper receives its file descriptor at spawn, that RTF and Word load from bytes the app reads in full, and
  that a later milestone builds the shared helper bundling and handshake. The shipped design passes the descriptor with
  each decode request over `SCM_RIGHTS`, as the image helper does, so the app never reads an RTF or Word file's bytes.
  It starts one helper for each decode. UTERM-006 landed first, so this milestone factored its framing, supervision,
  and liveness rules into shared targets, and each helper keeps its own protocol and handshake. The Dependencies line
  for UTERM-006 said whichever proposal lands first builds the shared helper bundling, and now says M1 built it.
  (work-queue best guess)
- 2026-11-08: M1 caps. A PDF reads up to 256 MiB, since PDFKit's decoded pages use more memory than the file. An RTF or
  Word file passes up to 64 MiB to the helper. A decoded document may hold 4,000,000 UTF-16 characters, 20,000 table
  cells, and 64 images, each up to 16,000,000 pixels and 64,000,000 together. The helper's archive may be 32 MiB. The
  app ends the helper at a 1 GiB footprint and at 10 seconds, following UTERM-006. The numbers rest on the data
  viewer's per-file cap and on UTERM-006's helper limits. A document past a cap shows a message that names it.
  (work-queue best guess)
- 2026-11-08: The format rule reads names only: `README` with no extension and the Markdown extensions are Markdown, and
  other extensions go through the system type database. Markdown shows the unsupported-type message and is not declared
  as an opened type until M2, so Cmd-O does not route a Markdown file to a viewer that cannot show it. (work-queue best
  guess)
- 2026-11-08: The document page stays white with the document's own text colors in every theme, since an RTF or Word
  file names black text for white paper. The theme colors the surround, the PDF background, and the messages. (work-queue
  best guess)
- 2026-11-08: Each decode starts its own helper and ends it when the decode ends. Keeping one helper for the pane's
  life would need a refcount of what it holds and would leave a process behind an idle pane. The cost is one spawn for
  each RTF or Word load. (work-queue best guess)
- 2026-11-08: Unowned finding. The system RTF, Word 97, and Word XML readers returned no picture attachments for any
  sample on the macOS used. Embedded pictures therefore do not appear in this run, though the path for them is built
  and tested with attachments made in code. Revisit when a reader that does return attachments is found on a supported
  macOS.
- 2026-11-08: Amended "Markdown rendering" while building M2. The CSP sentence said "allows
  images only from its own scheme". The page also reads its stylesheet and the document's text from the scheme, by
  fetch, so the policy allows `style-src` and `connect-src` for that scheme alone, and `script-src 'none'` still holds
  because WebKit exempts user scripts in a content world from the page's policy. (work-queue best guess)
- 2026-11-08: The payload stays at version 1. The Markdown anchor's source line and fraction are optional fields of it,
  and a payload without them reads unchanged. ADR-06 bumps the version for a field that an older reader would drop. No
  build outside this branch has read a version 1 text viewer payload, since M1 has not left it, so no older reader
  exists to drop them. An entry written earlier today called the bump required and set version 2. This entry replaces
  that reading. (work-queue best guess)
- 2026-11-08: Amended M2's check "After a scroll and an immediate layout save, reopen lands on that scroll position".
  `describe()` is synchronous and reads the host's cache, and the page reports a scroll by message from its scroll
  handler. A save taken in the same turn as the scroll, before that message arrives, cannot hold the new position,
  and no host call can read the page without waiting for it. The check now says a save taken after the page's scroll
  report arrives lands there. The report follows the scroll by one message, with no timer. (work-queue best guess)
- 2026-11-08: M2 caps and mechanics. A Markdown file reads up to 32 MiB, and one image up to 16 MiB. The parse happens
  in WebKit, so the cap bounds the content process and the host's one read. Relative image references are rewritten
  by the world's script to `image?p=<path>` after sanitizing, because a relative URL collapses `..` before the handler
  sees it. Links keep only `http`, `https`, and `mailto`, and `srcset` stays only on `<source>`. The rule list is
  compiled once into WebKit's default rule list store, and a pane that cannot compile it shows a message and loads
  nothing. Reload is a pane method and a button on the process-ended message, with no key and no command. (work-queue
  best guess)
- 2026-11-08: M2 measurement. A 20 MB Markdown file of 285,000 short paragraphs reached its rendered state in 87 s with
  fixed 30 ms slices, because each yield made WebKit lay out the whole document again. Slices that grow with the last
  yield's cost brought it to 4 s. Parsing took 0.6 s and sanitizing 2.6 s of the original run. The host's longest
  main-thread gap was 0.03 s either way. One run on one machine. (work-queue best guess)
- 2026-11-08: ADR candidate (cuts across the system): a path named by a document's content never leaves the
  document's volume and never triggers an automount, whatever viewer follows it. M2's Markdown images are the first
  case, and the map viewer and any later viewer of linked files would follow the same rule. Undecided. Found in
  UTERM-007 M2.
- 2026-11-08: Amended "The applet contract" (the snapshot sentence), M1's rewritten-PDF check, and "Live reload" while
  building M3. The contract text said a later change to the file never reaches a view that is showing, and the M1
  check said a PDF rewritten in place keeps rendering the loaded document. Live reload now reloads such a change. A
  load is still one full read of the file, and no mapped or lazy file backs the view afterward. A reload reads
  whatever bytes are there, and PDFKit may accept a truncated PDF, so the guarantee is not that a half-written file is
  never shown. A failed parse keeps the last render, the settle delay only makes a partial read less likely, and the
  next write reloads again. The shown document changes only when a reload succeeds. (work-queue best guess)
- 2026-11-08: M3 watcher mechanics. The map viewer's watcher moved into a shared `FileWatching` target and gained a
  folder watch, a signature filter, and coalescing, with the map keeping its old behavior as a policy. The numbers are
  0.15 s of quiet and a one second ceiling. A burst of RTF or Word saves would otherwise start a decode for each
  write. A missing path or folder is looked at without limit, at half a second and then five seconds, for the text
  viewer, since the proposal says the file reloads when it reappears and sets no time. The map keeps its ten looks.
  (work-queue best guess)
- 2026-11-08: A watcher event during a load queues one reload after the load, not a cancel and restart. Restarting would
  starve a file that is rewritten without pause, since each restart discards the decode in progress. Reload (Cmd-R)
  and opening another file still end the running load, and its helper, first, so no second decode runs beside one. This
  is M1's "a reload never starts a second decode while one runs" for the watch, and its supersede rule for the
  commands. (work-queue best guess)
- 2026-11-08: Reload sits in the View menu on Cmd-R, the browser's reload key, and is off for a pane with no file.
  UTERM-007 M4 lists Reload among the registry commands, and this milestone declares it. The status bar text for a gone
  file is "Moved or deleted" as a warning segment, and the one warning says the pane keeps the last version it read.
  (work-queue best guess)

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, APPLET-7
