# UTERM-006: Image Viewer Applet

**Status:** accepted
**Created:** 2026-10-31
**Updated:** 2026-11-09

## Dependencies

- UTERM-001
- UTERM-002's command registry and UTERM-013: the viewer's zoom and navigation commands are registry entries it
  declares
- UTERM-003 M2 and UTERM-004 M2 and M3: M4's control and exec support
- UTERM-015: app-level opening, and the path-reading power M4's `show` uses

## Impacts

- UTERM-004 — "Control levels": the image viewer's supported combinations and command schema
- UTERM-003 — "Control levels": "send a document to an applet" maps onto the viewer's `show` command
- UTERM-009 — "Rendering": decoding untrusted files through OS code uniterm does not own runs in a sandboxed helper
  here, which bears on UTERM-009's waiting ADR candidate about in-process parsing
- UTERM-009 — "Control levels": UTERM-015 defines the path-reading power under ADR-09 for both viewers

## Summary

An image viewer applet. It shows one image, or steps through the images in a folder as a slideshow.

## Motivation

Viewing images from the terminal usually means leaving uniterm for Preview or Finder. An image pane keeps them beside
the work that produced them.

## Design Decisions (Settled)

### Folder slideshow

Given a folder, the applet steps through its images in order. Given one file, it shows that file and can step through
its siblings.

### Rendering

Original question: QuickLook's `QLPreviewView`, which brings broad format support but which the write-up notes is not
always pleasant; a custom view on ImageIO, with full control over zoom, panning, and transitions but image formats
only; or QuickLook first, replaced by a custom view when its limits show.

Decision: a custom view, fed by ImageIO decoding in a sandboxed helper process, one helper per image pane.

- The app never parses image bytes. It types a file by its extension and UTType only. Every `CGImageSource` call,
  header and property reads included, runs in the helper.
- The helper is a second helper executable beside UTERM-003's Janet helper. It carries its own App Sandbox
  entitlements, with no file access and no network. It is the project's first OS sandbox profile.
- The app opens the file off the main thread, checks that the opened descriptor is a regular file, and passes the
  descriptor to the helper.
- The helper talks to the app only over a private socketpair it inherits at spawn, with a decode-only protocol. It
  never connects to UTERM-003's listener, so a compromised decoder has no path to the host API.
- Both sides exchange a protocol version when they connect, and refuse a mismatch with a message to relaunch uniterm,
  as UTERM-003 does for bundle skew.
- The helper decodes downsampled to the displayed pixel size. It applies EXIF orientation itself. It converts every
  image into one of a fixed set of named output spaces, such as sRGB, Display P3, extended-linear Display P3, and
  BT.2100 PQ or HLG. The app never builds a color space from profile bytes the helper sends, and treats every helper
  message as untrusted.
- The app reads each helper's footprint and kills one past a per-helper cap. An app-wide budget bounds image helpers
  together, as UTERM-003 bounds REPL helpers.
- Cancellation is latest-wins: at most one decode in flight and one pending per pane. The app kills a helper only on
  close, or when an in-flight decode overruns a time bound. A crash, a hang, or a memory blowup ends that pane's helper
  only. The pane says why and offers a retry.
- The viewer prefetches one image, the next in the stepping direction, at fit size, only when no step or tile request
  is waiting. A request that arrives while the prefetch is pending replaces it. A prefetch already decoding runs to
  completion, and the waiting request goes next, so the added wait is at most one fit decode. A pane zoomed past fit
  does not prefetch. The previous image's fit decode is kept after a step.
- The view steps animated frames itself, and pauses them on detach, per ADR-05.
- The supported set is whatever `CGImageSourceCopyTypeIdentifiers` reports on the running macOS, kept to the types that
  conform to `public.image`. Before the helper answers, the open panel and the folder listing accept any type that
  conforms to `public.image`. Amended 2026-11-07; see Decision Log.

Rationale: ADR-07 asks each new applet that hosts code uniterm does not control to show how its failures are contained,
and here isolation is possible. Images arrive from Downloads and mail. ImageIO has had memory-corruption bugs exploited
through crafted images, such as CVE-2025-43300, and with the App Sandbox off an in-process decoder runs beside live ssh
sessions with the user's privileges. UTERM-009's in-process stance does not fit here. Its caps live in Swift that
uniterm owns, and uniterm owns no code inside ImageIO, so it can set no caps there. Fuzzing ImageIO can find a bug but
cannot fix it. `CGImageSource` has no cancellation API, so an in-process decode that spins after close stays pinned,
against ADR-05. ImageIO has no general region decode, so a 1:1 crop of a huge image, or a small file declaring huge
dimensions, decodes the whole image, and a failed allocation inside ImageIO would abort the app. One shared helper was
weighed. A hostile image would then abort every pane's decode, and the cap would not be per pane. `QLPreviewView` has no
zoom, pan, or pause API, handles keys internally, adds PDF, video, and Office documents to an image viewer, and does not
document where it decodes, so containment cannot be shown. Quick Look thumbnails are still images only. QuickLook first
discards its view work and ships those limits meanwhile.

Left undone: PDF, video, and other non-image files do not show; UTERM-007 owns documents. The helper costs a second
executable, its sandbox entitlements, and an IPC contract within one bundle.

### Input sources

Original question, raised in this review: how an image or a folder reaches an image viewer pane. The draft did not say.

Decision: files and folders open from inside the pane, following UTERM-009's "Input sources".

- The launcher offers the image viewer, and the pane starts empty. Inside it, the user opens a file or a folder with an
  open panel, from an Open... registry command with no key in the File menu, or drops file URLs onto the pane.
- A pane shows one source, a file or a folder. Opening another replaces it, and a slideshow that was playing stops.
  The open panel selects one file or one folder. A drop of several items is refused with a status bar warning asking
  for one file or folder, and the pane keeps what it showed. The source stays one file or one folder, in the
  description and in `show`, as UTERM-009 settles for the data viewer. Amended 2026-11-05; see Decision Log.
- A drawer of open documents beside the image, as Preview has, is an idea for later. This proposal does not commit to
  it. Building it needs its own proposal, since it changes what a pane and its description hold.
- All loading goes through one internal entry point that takes a source.
- App-level opening belongs to UTERM-015. Its File > Open on Cmd-O routes files here by type, and this Open... is the
  pane-local open it keeps. The image viewer declares `public.image` at the owner rank and `public.folder` at the
  alternate rank, since the terminal owns folders. It binds no File > Open key.
- Script and terminal input belongs to "Control levels".

Rationale: UTERM-009 settled the boundary for every viewer from UTERM-006 to UTERM-009, and its hook asks for the
cross-applet proposal before a second viewer starts its first milestone. A hook in this decision states that trigger
for this applet directly. A Dependencies line naming an unfiled proposal could not be scheduled against. Filing that
proposal in this review would draft a cross-applet design without an interview, inside a review of a different
proposal. A launcher entry that takes a path would be a second route from a path to a pane, beside whatever the
cross-applet proposal decides. The open panel already takes a typed path with Cmd-Shift-G. Deciding app-level opening
here would reverse UTERM-009's settled decision.

Left undone: drags that deliver file promises or raw image data, such as from Photos or Safari, are refused, and pasting
an image is not supported.

### Zoom

Original question: fit to pane, actual size, and free zoom with panning.

Decision: all three, with a fit-size backdrop and a bounded tile cache in the app.

- Fit is the default. It shrinks a large image and never enlarges a small one past actual size. Stepping to another
  image returns to fit.
- Actual size shows the image at the size Preview shows it, honoring its resolution metadata, so a Retina screenshot
  is not doubled.
- Free zoom comes from pinch and from View menu commands the viewer declares in UTERM-002's registry: Zoom In (Cmd-+),
  Zoom Out (Cmd--), Actual Size (Cmd-0), and Zoom to Fit (Cmd-9). Scrolling pans. None of these is a reserved window
  key, and the terminal's items with the same keys show only while a terminal pane has focus, per UTERM-013. An
  animated image zooms by the same commands and gestures. Amended 2026-11-07; see Decision Log.
- The decode scale is the smallest power-of-two fraction of native that is not below the zoom, and never more than
  native 1:1. Zoom above 1:1 magnifies the native decode, with nearest-neighbor sampling, and needs no larger decode.
  Amended 2026-11-07; see Decision Log.
- The app keeps the fit-size decode as a backdrop. The helper keeps its decode and sends tiles, and the app caches a
  bounded set around the viewport, so app memory tracks the pane, not the image. During a pinch the app scales what it
  holds, and asks for crisp tiles when the gesture ends.
- An animation has no tiles. While it is zoomed past fit, the helper decodes each frame whole at the zoom's decode
  scale, capped at 1:1, and the animation keeps playing from those frames. The fit-size still stays as its backdrop. A
  frame costs its size times the zoom, and the window of frames is charged to the bitmap budget. Zoom to Fit brings the
  fit-size frames back. Amended 2026-11-07; see Decision Log.
- One app-side budget covers every bitmap image panes hold: backdrops, tiles, the prefetched and previous images, and
  animation frames.
- Zoom past what the helper cap, the app-wide helper budget, or the bitmap budget allows is refused, and the status bar
  says the limit was reached. Another pane's helper is never killed to make room. A refused zoom goes back to the last
  zoom that showed tiles, or to fit. An animation goes back to the last zoom whose whole window of frames was held, or
  to fit. Amended 2026-11-07; see Decision Log.

Rationale: the draft names all three modes, and a viewer for screenshots and photos needs detail at 1:1. A backdrop
keeps panning responsive while tiles arrive, as ADR-08 requires, where a viewport-only transfer would show blank edges
and send a full buffer per pan step. Decoding above 1:1 would cost the square of the zoom in memory for no added
detail. Holding the whole decode in the app would put the largest bitmap where it cannot be killed. Fit and actual
size alone would drop the free zoom the draft lists, and deferring zoom would rework M1's helper protocol later.

### Control levels

Original question: which UTERM-004 levels the viewer supports. A script might send it an image or a folder to show.

Decision: the viewer supports remote-controlled and disconnected access, and an exec driver, with its own schema. The
power to read a path for a controller is defined once, outside this proposal.

- Commands: `show` (a file or folder path), `next`, `previous`, `first`, and `last` in the order "Navigation" settles,
  and `zoom` (fit, actual, or a scale). Event: `shown`, with the path, the index, the count, and whether the count is
  still partial while the folder lists.
- When the pane's source lies outside the controller's directory scope, whether the user opened it or a restore found
  it, `shown` carries no path, index, or count, only that the image is outside scope. `next`, `previous`, `first`, and
  `last` from that controller are refused with the scope error, since stepping would reveal what the folder holds.
- UTERM-003's "send a document to an applet" maps onto `show`. Every path, from a controller, a script, or the pane
  itself, goes through the one source-taking entry point.
- Asking the viewer to read a path is its own power under ADR-09, apart from pane control. It carries an explicit
  directory scope, checked against the real path of the opened descriptor, so a symlink or a rename cannot widen it.
  Errors for paths outside the scope do not tell "missing", "not an image", and "denied" apart.
- That power is defined in UTERM-015, so UTERM-005, UTERM-007, and UTERM-009 share one definition.
- Schema compatibility: the schema version is a major and a minor, carried in UTERM-004's hello. A new command, or a
  new optional event field that drivers ignore, bumps the minor. A driver that needs a newer command requires that minor
  in the hello, so an older viewer is refused before any effect instead of failing midway. A change in meaning, or a
  removed command, bumps the major, and the handshake refuses the mismatch.
- M4 builds it after UTERM-004's M2 and M3, UTERM-003's M2, and UTERM-015's M4, which builds the power. Amended
  2026-11-03; see Decision Log.

Rationale: UTERM-009 deferred script input because caller identity and the exec wire format were unsettled. UTERM-004
has since settled both, and asks each applet's proposal to carry its combinations and schema. Deferring would fail the
draft's stated use. A host function alone would rule out exec and remote control, which UTERM-004's presentation
example needs, and would still read a path. ADR-09 lists no file-read power, and UTERM-005, UTERM-007, and UTERM-009
each need the same one, so defining it inside one applet would let the definitions diverge. Without a directory scope a
script with no file capability could probe which files exist, and borrow uniterm's privacy grants for Downloads and
Documents.

Left undone: image bytes sent without a file are not accepted. That needs a chunked transfer and a restore rule for an
image that had no file, the question UTERM-009 also left open.

### Navigation

Original question: keyboard keys for next, previous, first, and last; whether the slideshow advances on a timer; and
sort order by name, date, or both.

Decision: view keys plus registry commands, a play and pause timer at a fixed interval, per-pane name or date order,
and a folder listing taken once, with Reload.

- While the image view has focus, Right and Left arrows and Space and Shift-Space step next and previous, and Home and
  End go to the first and last image. When zoomed past fit, arrows pan instead, and Space still steps.
- Next Image, Previous Image, First Image, Last Image, Play or Pause Slideshow, Sort by Name, Sort by Date Modified, and
  Reload Folder are registry commands in an applet menu named for the viewer. None carries a default chord. A
  text-editing chord such as Cmd-Left would reach the menu before the palette's search field, and the palette would
  close and run it. Amended 2026-11-07; see Decision Log.
- Manual stepping stops at the first and last image.
- Play or Pause Slideshow is one command, since a registry command has one title. Playback advances every 5 seconds and
  wraps at the end. A manual step stops it, and so does zooming past fit, from the start of a pinch. It pauses on detach
  and resumes on reattach only if it was playing. A status segment shows it is playing. The interval is fixed, with no
  setting, and playing state is never saved. Amended 2026-11-07; see Decision Log.
- Name order is Finder's: localized and numeric-aware, so `img2` comes before `img10`. Date order is the file's
  modification time, newest first, with ties in name order. Capture dates would mean reading EXIF in the app, which
  "Rendering" rules out.
- The folder is listed once, off the main thread, when it opens. The user can step while the listing runs, through what
  is listed so far, and the index and count stay provisional until it ends. While it runs, images keep the order they
  arrive in and each batch is ordered within itself, so nothing already listed moves. The listing takes the chosen order
  when it ends, and the selection follows its image. A folder opened fresh shows the first image of the first batch
  until then. The position segment marks a provisional count with a plus sign. Reload Folder lists it again and keeps
  the current image, or lands on the image nearest its old position when it is gone. Amended 2026-11-07; see
  Decision Log.
- A file deleted since the listing posts a status bar warning when reached and is skipped. An image the pane already
  holds a decode of, the one it just left or the prefetched one, shows from that decode, and a deletion is found at the
  next step that needs the file. Given one file, its siblings are listed the same way, starting at that file. When that
  folder cannot be listed, the pane shows the file, the status bar says so once, and a "Folder not listed" warning
  segment shows while that holds. Subfolders and hidden files are not included. Amended 2026-11-07; see Decision Log.

Rationale: plain keys cover the focused case, as Preview does, and registry commands give the menu and palette a way in
without claiming a chord the palette's text field needs. A timer is what makes a folder a slideshow, and one fixed
interval follows CLAUDE.md's rule that not every behavior needs a setting. An adjustable interval has no named user.
Live folder watching was weighed. It would reorder the list under the user while stepping or playing, and FSEvents can
drop events on network mounts, which leaves the list silently stale where Reload is explicit. Keys and name order alone
would drop the timer and date order the draft raises.

Left undone: an image that arrives after the listing does not appear until Reload.

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

For the image viewer: a description likely holds the folder and the current image. The viewer likely never counts as
running something.

Decision: the image viewer needs no change to the applet contract or the factory. Its description holds a path, a
bookmark fallback, the current image, the sort, and the start directory, and never any image data.

- The payload holds the opened source's absolute path, a file or a folder, and a macOS bookmark of it. It also holds
  the current image's file name and its modification time from the listing, the sort order, and the directory the
  pane started in, which the factory passes. It has its own version, per ADR-06.
- Restore opens the stored path when it is there and of the stored kind. It uses the bookmark only when the path is
  missing, and then says where it found the source. When the current image is gone, it lands on the nearest image in
  sort order, using the stored name and modification time. For a single file, restore shows the stored current image of
  the file's folder. When the file and its bookmark are both gone, it opens the current image in the file's old folder,
  and the pane says where it found it. Amended 2026-11-07; see Decision Log.
- Zoom, scroll position, and playing state are not saved. A restored pane shows its image at fit, paused.
- An empty pane reports its start directory as `currentDirectory`. With a source open, the pane reports the viewed
  folder. The open panel starts in `currentDirectory`, never in AppKit's remembered folder.
- The bookmark is made at load, and remade when an open finds a different file than the bookmark names. Resolution runs
  in `start()`, off the main thread, without UI and without mounting volumes. `describe()` never touches the disk.
- The viewer never counts as running something, so closing it never asks, playing or not.
- It publishes one tab for its session, titled with the current image's name, per UTERM-002. Cmd-Shift-T reopens a
  closed viewer from its description, per UTERM-013.
- A pane a controller filled restores the same way, disconnected and with no grant, per UTERM-004.

Rationale: UTERM-009 settled this pattern for viewers, and nothing about images needs another. The path is what the
user named, so it wins while a file is there, and the bookmark recovers a moved or renamed source. Bookmark-first
resolution would show a renderer's rotated-away output instead of the fresh file. "Zoom" treats zoom as passing state
that resets on every step, so saving it would write passing state into the layout file. Restored zoomed panes would
also compete for the helper budget at launch. A stored modification time places a deleted image in date order, where
the name alone could not. Storing image data would contradict "Rendering", write file contents into the layout file,
and make ADR-06 keep them byte-for-byte in an older build.

## Design Decisions (Open)

None.


## Risks

- **A hostile image exploits the decoder** — likelihood: medium, impact: medium. Images arrive from Downloads and mail,
  and ImageIO has had exploited memory-corruption bugs. Mitigation: decoding runs in a sandboxed helper per pane with
  no file or network access, the app never parses image bytes, and it treats helper messages as untrusted and sizes
  pixel buffers itself. What remains is a sandbox escape, which macOS updates patch, or a bug in the app's message
  checks, which M1 tests.
- **The sandboxed helper cannot decode some formats** — likelihood: medium, impact: medium. Some ImageIO codecs may
  need resources a sandbox with no file access denies, and the helper is the project's first sandboxed target.
  `scripts/check-sandbox-off.sh` keeps the app out of the App Sandbox by checking entitlements under `App/`.
  Mitigation: M1 decodes a sample of every type the helper reports, under the shipped sandbox, and a type that fails
  shows a message naming the format. The helper's entitlements live outside `App/`, and the check keeps guarding the
  app.
- **UTERM-015 reshapes opening or the read power** — likelihood: low, impact: medium. It is accepted. It keeps the
  in-pane panel and drops, adds the pane-local Open..., and defines the power M4 needs. Mitigation: M1 declares the
  viewer's types, and M4 starts after UTERM-015 M4.
- **UTERM-003 and UTERM-004 are accepted but not built** — likelihood: medium, impact: low. If M1 lands before UTERM-003
  M1, it builds the first bundled helper target and version handshake itself. Accepted: the image helper's protocol is
  private and decode-only, so it shares no wire format with the Janet helper, and either can land first.
- **Some legitimate images never show** — likelihood: low, impact: low. Some codecs decode fully before downsampling, so
  a very large PNG or TIFF can pass the helper cap even at fit. Accepted: the pane says the image is past the limit,
  and Preview still opens it.
- **A memory spike passes the cap between footprint reads** — likelihood: low, impact: low. Accepted: the spike lands
  in the helper, not the app, and the app kills the helper at its next read.
- **Large folders list slowly** — likelihood: medium, impact: low. Mitigation: listing runs off the main thread, and the
  user can step while it runs.
- **The description and the control schema are stored data and a published contract** — every later build reads the
  payload, and deployed drivers outlive builds. The design defuses both one-way doors. The payload carries its own
  version per ADR-06, and an unreadable description is kept. The schema's major and minor versions let either side
  refuse before any effect.

## Milestones

### M1: Show one image

**Status:** DONE

- A pane can run the image viewer and show a chosen image
- The image fits the pane and rescales when the pane resizes
- The viewer declares `public.image` at the owner rank and `public.folder` at the alternate rank, for UTERM-015's router
- The launcher offers the image viewer. An image or a folder opens from an open panel that accepts both, reached from
  the Open... command with no key or the empty pane, or by dropping file URLs on the pane, through the one
  source-taking entry point
- Opening a source into a pane that shows one replaces it and stops any slideshow. A drop of several items is refused
  with a status bar warning asking for one file or folder, and the pane keeps what it showed. A drop with no file URL
  posts a warning that says why it was refused. Amended 2026-11-05; see Decision Log.
- The app reads no image bytes: it types files by extension and UTType only, and every ImageIO call runs in the helper
- The shipped helper cannot open a file by path or make a network connection
- The regular-file check runs on the opened descriptor, so swapping the path after the check cannot slip past it
- Pixels cross from the helper in a buffer the app sized from dimensions it checked against its cap, and a mismatch is
  refused
- A crafted file that crashes, hangs, or exhausts the helper ends only that pane's decode. The pane says why and offers
  a retry, and every terminal keeps running
- An app and a helper from different protocol versions refuse each other, with a message to relaunch uniterm
- A Display P3 image and an HDR image look the same as in Preview, and EXIF orientation is applied
- An animated image plays, and pauses on detach. A long animation streams its frames within the bitmap budget without
  starving step and tile requests
- The app knows the supported types without reading image bytes, and a type list that includes PDF still leaves PDF
  unopened
- A new or restored image pane while the helper or bitmap budget is exhausted shows its image at fit, or says why it
  cannot, never a blank pane, including many image panes restored at launch
- `scripts/check-sandbox-off.sh` still checks and passes for the app, whether the helper's sandbox comes from an
  entitlements file outside `App/` with the build setting left off, or the script is scoped to the app target
- A sample of every type the helper reports decodes under the shipped sandbox, or shows a message naming its format
- A helper exits when its socket closes, so none outlives a crashed app
- The app opens files read-only and non-blocking, so a FIFO never blocks the worker before the regular-file check
- A legitimate decode killed for overrunning its time bound reports a limit, not a retry that repeats the overrun
- M1 records a helper's resting footprint and spawn time in its As built block
- Reopen and relaunch bring back the source and the current image, at fit, and an empty pane reopens empty in its
  start directory
- A source moved or renamed after the save is found through its bookmark, and the pane says where. A new file at the
  stored path wins over the bookmark, and the bookmark is then remade for it
- The open panel starts in the pane's `currentDirectory`. When the viewed folder is gone, `currentDirectory` is the
  start directory, or nil when that is gone too
- A layout save never touches the disk to describe a pane, and an unchanged pane describes itself the same way twice
- Closing an image pane never asks, even while the slideshow plays

**As built:**

- The helper is a native Xcode tool target with its entitlements file outside `App/`. The build setting
  `ENABLE_APP_SANDBOX` is left unset for it, so `check-sandbox-off.sh` still sees `NO` on every line. Xcode signs the
  debug copy under `Contents/Helpers/ImageDecoder` with `com.apple.security.app-sandbox` and `get-task-allow`.
  `codesign -d --entitlements -` on the built app confirmed it. A release build was not signed in this run.
  The script now also asserts that the helper holds the sandbox and no file, network, or exception entitlement, in the
  source file and in a built app.
- Crash, stopped process, overrun, and over-cap behavior is proved against an unsandboxed SwiftPM build of the helper,
  with faults that a debug build reads from a marker at the start of a file. The shipped helper's sandbox probe, the type
  sample, and the signed entitlements are checked by `make test-helper-sandbox` and `check-sandbox-off.sh <app>`, which
  need a shell outside the agent's own sandbox.
- A hung helper and a slow one are told apart by a ping the helper answers from its reader thread. A helper that stops
  answering is a hang and offers a retry. One that answers past the time bound reports a limit and offers none.
- Spawn to first reply took about 27 ms, and a helper's resting footprint was 3 MiB, for the unsandboxed debug SwiftPM
  build. The shipped sandboxed helper was not measured.
- Run-wide guesses: the per-helper cap is 1 GiB, the app-wide helper budget is the smaller of 4 GiB and a quarter of RAM
  with a 256 MiB floor per pane, the bitmap budget is the smaller of 1 GiB and a quarter of RAM with a 256 MiB floor per
  pane, and the decode time bound is 10 seconds. See Decision Log.
- The HDR path decodes a source that carries a gain map or an HDR color space into extended-linear Display P3 half-float
  pixels, and the layer asks for high dynamic range. Tests cover the space mapping and that values above white survive in
  half float. No test decodes a real gain-map file, so an HDR image's match with Preview is left to the screenshots.
- The sandboxed run sampled 18 of the 58 image types the helper reports. The other 40 cannot be sampled, because they
  have no encoder or the encoder writes an empty file: the RAW formats, `com.microsoft.dds`, `com.apple.pict`,
  `com.sgi.sgi-image`, `org.nema.dicom`, `org.webmproject.webp`, `public.avci`, `public.heif`, `public.jpeg-xl`,
  `public.mpo-image`, and `public.radiance`. A file of one of those types that fails to decode shows the helper's
  message, which names the format.
- Orientation on the whole-image decode path, which a gain-map image takes, is applied by drawing, since ImageIO applies
  it only when it makes a thumbnail. A test compares all eight orientations on that path with the thumbnail path.
- The helper writes an image reply as a prefix and the pixels, so no joined copy of the image is made. On a 3000 by
  2000 native decode the helper's peak footprint was 72 MiB for 22 MiB of pixels in the unsandboxed debug build. The
  decode sets that peak, so it did not change.
- The open panel gained content types through `SourceReplacing.openPanelContentTypes`. Folders stay choosable.
- Left to the person reading a run: the Display P3 and animation screenshots from the UI tests, compared with Preview.
  No UI test resizes the window, since package tests prove the rescale and the sharper decode on resize.
- The launcher entry is last, after the browser, so the browser keeps Cmd-5 and the image viewer takes Cmd-6.

### M2: Folder slideshow

**Status:** DONE

- Given a folder, the viewer steps forward and back through its images by keyboard
- Non-image files in the folder are skipped, judged by extension and UTType only
- Listing a folder runs off the main thread, and a folder on a stalled mount never blocks the UI
- Holding the next key through a folder of large HEIC or RAW files keeps showing images, without respawning the helper
  per key repeat
- Next, Previous, First, Last, Play, Sort, and Reload are registry commands with no default chord, and Cmd-Left in the
  palette's search field moves the caret while an image pane has focus
- The slideshow advances every 5 seconds and wraps, stops on a manual step, pauses on detach, and resumes on reattach
  only if it was playing
- Name order matches Finder's for numbered files, and date order is newest first with ties in name order
- Stepping works while a large folder is still listing, and Reload keeps the current image or lands nearest it
- When the folder of a single opened file cannot be listed, such as under macOS privacy protection, the pane shows that
  file, never an empty pane. The status bar says so once, and a "Folder not listed" warning segment shows while it
  holds. Amended 2026-11-05; see Decision Log.
- Restoring into a large folder opens the stored image at once, without showing the first image while the listing runs
- Stepping during a partial listing keeps a stable order, and the slideshow does not wrap before the listing ends
- The slideshow stops when every remaining file has been deleted, and the status bar says why
- Reload and restore land on the same image when the current one is gone
- A single-file source is restored from its stored path, then its bookmark, then its old folder for the current image,
  in that order
- Stepping is fast after a prefetch. A step or tile request replaces a pending prefetch and waits at most one fit
  decode behind one in flight, and a pane zoomed past fit never prefetches or passes its helper cap by prefetching
- A prefetch that crashes, hangs, or overruns leaves the current image on screen with no error. The message appears
  only when the user steps to that image
- A step to the image being prefetched uses the prefetch's result, without a second decode
- When a single-file source is gone but its folder and the current image remain, restore opens the current image in
  that folder
- When the current image is gone, restore lands on the nearest image in the stored sort, by name or by date

**As built:**

- The helper keeps up to four opened sources, keyed by the IDs the protocol already carries, and drops the one decoded
  longest ago past the limit. This lets the pane open the next image for a prefetch without losing the one on screen.
  The wire format and the protocol version are unchanged. A decode of a dropped source fails as stale, and the pane
  reopens the image.
- The pane keeps at most three fit-size bitmaps: the one on screen, the one it just left, and the prefetched one. All
  three are charged to the bitmap budget. A decode for the image on screen gives way to the other two when the budget is
  short, so the pane never goes blank for memory a prefetch holds.
- A step to a held decode shows it at once with no request to the helper. A step to the image being prefetched waits for
  that decode and shows it, with no second decode. The prefetch runs only when the pane shows an image and nothing is
  loading. A prefetch pending behind a decode is replaced by any other request. A prefetch that fails, hangs, or
  overruns leaves the image on screen with no message and is not tried again until a reload. Stepping to the file shows
  the failure.
- The scheduler holds the zoom gate as `isZoomedPastFit`, which the pane sets once the image is zoomed past fit. See
  the M3 As built. It refuses prefetches and drops a waiting one while it holds. The arrow keys pan a zoomed image,
  which M3 added.
- A step moves the selection at once, and the pane loads one image at a time. When one finishes, it loads whatever is
  selected then. A held key through large images shows each image as it arrives, and one helper decodes them all.
- A scan reports in batches of 256 images from its own thread. A test hook holds it between batches.
- Play or Pause Slideshow is one command, and its sort and reload siblings carry no chord. A test pins the commands'
  names, titles, menus, and absent keys.
- The slideshow takes its sleep as an injected function. Tests release it by hand.
- Reload lists again through the folder handle the pane already holds. A single file whose folder was not listed tries
  to open its folder again.
- A file whose folder cannot be listed shows the file, posts one warning, and shows a "Folder not listed" warning
  segment. A test uses a folder with no read bit. Under macOS privacy protection the real cause was not exercised.
- The screenshot attachments of the UI tests capture the uniterm window only. The attachment names are unchanged.
- New UI tests: `testViewKeysStepThroughAFolder`, `testTheImageViewerMenuStepsAndTogglesTheSlideshow`, and
  `testCommandLeftInThePaletteSearchFieldMovesTheCaretWhileAnImagePaneHasFocus`. They were built for testing and not
  run in the agent's sandbox.
- The scheduler reports a waiting prefetch that another request replaced, and the pane then loads a step that was
  waiting on it the usual way. A detach abandons a prefetch whose file is still opening the same way. Tests cover both:
  an animation whose frame requests replace the prefetch, and a held open that a detach cancels.
- The scan sorts the listing on its own thread, and a sort command sorts off the main thread. A synthetic 100,000-name
  listing took 0.66 s to sort in a debug build, so the main thread sorts nothing large. The pane reorders at the end of
  the scan or when the sort finishes.
- The client mirrors the helper's source order exactly, and selecting a cached source does not touch it. A stale frame
  request reopens the image like a stale still.
- No test times the 5-second interval in real time. The in-flight prefetch handoff is covered by the tests that replace
  or abandon the prefetch, and by one that proves no image decodes twice.

### M3: Zoom

**Status:** DONE

- Fit, actual size, and free zoom by pinch and by Zoom In, Zoom Out, Actual Size, and Zoom to Fit, which are registry
  commands the viewer declares, with none of their keys a reserved window key. An animated image zooms too, with frames
  decoded at the zoom scale. Amended 2026-11-07; see Decision Log.
- Fit never enlarges a small image. Actual size matches Preview's size for a small image and a Retina screenshot
- Panning a large image at actual size never shows blank edges past the backdrop, and the main thread never waits on
  a tile
- Peak app memory on a very large image stays bounded while zoomed and panned
- A slow but legitimate decode of a very large image reports in the status bar that the zoom limit was reached, never a
  crash
- Zoom past the helper cap, the app-wide helper budget, or the bitmap budget is refused with a status bar warning,
  and no other pane's helper is killed. The pane goes back to the last zoom that showed tiles, or to fit. An animation
  goes back to the last zoom whose whole window of frames was held. Amended 2026-11-07; see Decision Log.
- Moving the window to a display with a different scale requests new pixels
- A user remap of the shared "Actual Size" title moves the terminal's item and the viewer's item together
- On detach a zoomed pane releases its 1:1 decode, its tiles, and an animation's zoomed frames, and keeps only its
  backdrop. Amended 2026-11-07; see Decision Log.
- The helper releases a prefetched bitmap once sent, and zoom is never refused for memory a prefetch holds

**As built:**

- The protocol is at version 2. The helper reports each source's declared resolution as whole dots per inch, after the
  orientation applies, and zero when the file declares none. The app shows an undeclared file at 72 dots per inch and a
  Retina screenshot at half its pixel size. Two messages are new. A region request asks for a rectangle of the decode at
  one level, and a release drops that decode. The helper keeps one decode, for the last level asked for, so a pan costs a
  copy and not a decode. Its reply is an ordinary image reply, checked against a rectangle bound the app set.
- The viewport is pure model code: a scale in points per image pixel, a center in image pixels, and a pan clamp that
  never lets the pane show space past the image. The tile grid, the level, and the bounded tile cache are model code
  too. A pane holds the tiles under the viewport and one ring around them, and the cache capacity follows the pane's
  size in device pixels. A 6000 by 4000 image at 1:1 is 96 MiB. Panning across it at 300 points held at most the
  backdrop and 25 tiles, which is the test's bound, and stayed under 40 MiB.
- The view owns the zoom and the pan. A zoom, a pan, or a pinch moves the backdrop and every tile layer in the same
  turn, and never waits on a tile. A pinch scales what the view holds and reports once when the fingers lift. A test
  renders the layers and reads pixels, since a tile in the wrong corner passes any test that reads frames only.
- Tile requests go through the scheduler. A newer tile replaces a waiting tile, a still replaces a waiting tile, and a
  tile never replaces a waiting still. The pane asks for the nearest missing tile after each one arrives, so a step or a
  resize is never behind more than the tile in flight.
- A tile is charged to the one bitmap budget. When the budget is short, the images the pane keeps beside the one on
  screen give way first. Entering free zoom also drops the prefetched image. A test with a budget that holds only the
  backdrop and two more fit decodes shows the tiles taking the previous image's place with no warning.
- A zoom the helper's cap or the app-wide budget cannot hold is refused on the app's side before the helper starts the
  decode, and the status bar says the zoom limit was reached. The pane goes back to the last zoom that showed tiles. A
  test with a shared helper budget shows another pane's helper keeps its process and keeps decoding. A decode that runs
  past the time bound, or a helper that dies or passes its footprint cap while it makes tiles, also warns that the zoom
  limit was reached. The pane keeps its backdrop at fit and opens the image again in a fresh helper. A debug-only fault
  in a PNG's description makes the 1:1 decode slow, which is how the test reaches this.
- Moving to another image returns to fit, and releases the tiles and the helper's decode while the old source is still
  the shown one. Detach releases both sides' tiles and decode and keeps the backdrop. Reattach asks for the tiles again.
  A new display scale changes the fit decode's size and the tile level, and a test with a stand-in for the display
  scale shows both.
- Found and fixed: a bitmap the helper had sent stayed in its footprint after it was freed, because the allocator keeps
  freed blocks of that size. A 64 MiB prefetch left the helper at 67 MiB, and a released 1:1 decode did not leave
  either. Pixel buffers now come straight from the kernel in whole pages and return to it. Two tests failed before the
  change and pass after. The app's frame reads use the same buffers.
- The zoom commands sit in View, with Cmd-+, Cmd--, Cmd-0, and Cmd-9. A test shows no reserved key and no warning. A
  test applies one remap of "Actual Size" the way AppKit does, by title, and shows that it moves the terminal's item and
  the viewer's. A UI test does the same with a real launch argument. The status bar shows the zoom as a percent of
  actual size while the image is zoomed.
- Arrows pan a zoomed image by a fifth of the pane, and Space still steps. Dragging pans, which the panning check
  covers. A double tap on a trackpad toggles actual size, which no check names. See the Decision Log.
- New UI tests: `testZoomKeysShowActualSizeZoomInAndFit`, `testARemapOfActualSizeMovesTheViewersItemToo`, and
  `testTheViewMenuZoomsTheImageViewer`. They were built for testing and not run in the agent's sandbox.
- A step or resize that arrives while a level's first tile is in flight waits for that tile. See the Decision Log.
- Zooming past fit stops a playing slideshow. The client sizes the helper's kept level from
  the output space of the source's last decode, and as sixteen-bit floats while that is unknown. A refused request no
  longer moves its source up the client's recency list.
- Landed after the row review, as the user's decision in a hands-on review: an animation zooms. See the Decision Log.
  The viewport and the commands are the stills'. Frames go through the existing frame path with the zoom's level as the
  decode size, so the protocol stays at version 2. A zoomed frame is a whole frame, with no viewport region, since the
  helper keeps a level and cuts regions for frame 0 only. The pane keeps the window of the frame on screen and two
  ahead, drops the others at a level change, and keeps the frame on screen until its replacement arrives. A frame too
  big for the helper's cap or app-wide budget, a window the bitmap budget cannot hold, or a helper that overruns or dies
  while it decodes one, ends in the same refusal as a tile and the same return to the last zoom that held its whole
  window, or to fit. A request for a frame already in flight or waiting is no longer sent again. A frame magnifies with
  nearest-neighbor sampling past its level. A result for a zoomed frame whose level the pane has already left is
  dropped, not counted as a limit. A sharper fit still for a zoomed animation does not replace the zoomed frame on
  screen. Stepping away from a zoomed animation stops it until the next image is chosen. Eight-bit frames of a 1200
  by 1200 animation at 1:1 are 5.76 MB each, so the window is 17.3 MB beside the 1.44 MB still, whatever the frame
  count. A 500 by 500 animation shows at its native size in a 300 point pane, so zooming asks for no new frames.
- Left to the user: how smooth pinching and panning feel, and whether the detail at 1:1 matches Preview. Left to the run
  coordinator: the region path against the signed, sandboxed helper, and the UI tests. No test moves a window between
  two real displays. The HDR tile path has no real gain-map file.

### M4: Control

**Status:** NOT STARTED

- A controller or an exec driver can `show` a file or a folder, step through it, and set zoom, and receives `shown`
- A path outside the controller's directory scope is refused with one error, whether it is missing, not an image, or
  denied, and the scope is checked on the opened descriptor
- UTERM-003's send reaches the same `show` path
- An exec driver with a different schema version is refused before any effect
- `shown` marks its count as partial while a folder listing is still running
- A relative `show` path is refused
- A pane whose source is outside the controller's scope sends `shown` with no path, index, or count, and refuses that
  controller's stepping commands
- A driver that requires a newer schema minor is refused at the hello, before any effect
- A new event type or a new argument value, such as a new `zoom` mode, follows the minor or major rule, and an old
  driver never receives an event it cannot ignore
- When stepping in an in-scope folder reaches a symlink whose real path is outside the controller's scope, `shown`
  withholds the path, index, and count for that image
- A controller's `next`, `previous`, and `shown` never reveal a file outside its directory scope, even in a pane whose
  source was opened by the user or restored

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-11-01: Added "The applet contract" with context from UTERM-001's implementation.
- 2026-11-03: Review start: 2 milestones, 1 settled decision, 1 risk, no `**Live after:**` lines or row gates; no
  out-of-scope statements; proposal at commit e2da0f1. The user asked for a design review of the open questions, in
  autonomous mode, adopting UTERM-009's settled cross-applet patterns as defaults wherever they fit the image viewer.
- 2026-11-03: Added "Input sources" as an open question. The draft never said how an image reaches the pane.
- 2026-11-03: Rendering: a custom view on ImageIO decoding in a sandboxed helper per pane, over a private socketpair,
  with named output color spaces and latest-wins cancellation. UTERM-009's in-process stance was weighed and does not
  fit code uniterm does not own. Converged in 2 passes. (autonomous, addition: the project's first OS sandbox profile
  and a second helper executable, in scope while ADR-07 requires containment)
- 2026-11-03: Input sources: in-pane opening by open panel or drop, through one source-taking entry point. App-level
  opening stays with UTERM-009's cross-applet proposal, gated before M1 by a revisit hook. Converged in 2 passes.
  (autonomous)
- 2026-11-03: Zoom: fit, actual size, and free zoom; a fit-size backdrop and a bounded tile cache in the app, decode
  scale capped at 1:1, and one app-side bitmap budget. Added M3. Converged in 1 pass. (autonomous)
- 2026-11-03: Control levels: remote-controlled, disconnected, and exec support with a `show`, `next`, `previous`,
  `first`, `last`, `zoom` schema and a `shown` event, and a compatibility rule. Added M4. Converged in 1 pass.
  (autonomous, addition: a path-reading power under ADR-09 with a directory scope, to be defined in the cross-applet
  file-opening proposal, and M4's dependencies on UTERM-003 and UTERM-004 milestones)
- 2026-11-03: Navigation: view keys plus chord-free registry commands, a fixed 5-second play and pause timer that
  pauses on detach, Finder name order or newest-first date order, and a one-time listing with Reload. Converged in 1
  pass. (autonomous)
- 2026-11-03: The applet contract: no contract change. The description holds the source path with a bookmark fallback,
  the current image's name and modification time, the sort, and the start directory, and never image data. Zoom and
  playing state are not saved. Converged in 1 pass. (autonomous)
- 2026-11-03: Coherence review. Fixed four design-level findings: `shown` withholds the path, index, and count, and
  stepping is refused, when the source is outside a controller's scope; one idle-slot prefetch of the next image; a
  multi-file drop opens the first file, so the source stays one file or folder; and the schema carries a minor version
  a driver can require, so an older viewer refuses before any effect. Routed 19 findings to M1 through M4 as checks.
  (autonomous)
- 2026-11-03: Risk review. Rewrote Risks: the hostile-image residual, sandbox feasibility beside
  `scripts/check-sandbox-off.sh`, the unfiled cross-applet proposal, unbuilt UTERM-003 and UTERM-004, images past the
  cap, memory spikes between footprint reads, and the defused one-way doors. Rated the unfiled proposal high likelihood,
  medium impact, mitigated by the M1 gate. (autonomous)
- 2026-11-03: Re-check. An in-flight prefetch runs to completion and the waiting request goes next, since a decode
  cannot be cancelled without killing the helper. A pane zoomed past fit does not prefetch. Routed 5 findings to M1,
  M2, and M4. (autonomous)
- 2026-11-03: Final re-check converged. Routed 3 findings to M2 and M3. (autonomous)
- 2026-11-03: Review gate: kept all, including the sandboxed decoder helper, the path-reading power, and animated and
  HDR rendering.
- 2026-11-03: ADR candidate (cuts across the system): decoders for untrusted files that uniterm does not own run in a
  sandboxed helper, never in the app. Declined: ADR-07 already states the principle, and this is one instance of it.
- 2026-11-03: ADR candidate (cuts across the system): reading a path for a controller is its own scoped power under
  ADR-09. Waits on the cross-applet file-opening proposal, which defines the power and may reshape its scope.
- 2026-11-03: Accepted by the user after the review.
- 2026-11-03: Amended "Input sources" to match UTERM-009: a pane shows one source, opening another replaces it, and a
  drop of several items is refused with a message asking for one. Before, a multi-file drop opened the first file and
  said the rest were not opened. Noted a Preview-style document drawer as an idea that needs its own proposal. The
  user's decision.
- 2026-11-03: Revisit-hook audit for "Input sources": act. The cross-applet file-opening proposal is filed as
  UTERM-015, and it is now in Dependencies. The hook's line is removed. 006 is not schedulable until UTERM-015 is
  accepted.
- 2026-11-03: Amended "Input sources" and "Control levels" for UTERM-015, the cross-applet file-opening proposal.
  App-level opening and Cmd-O waited on that proposal, and M4 waited on it for the read power. UTERM-015 is accepted. The
  viewer gains an Open... command with no key, declares `public.image` as owner and `public.folder` as alternate, and
  M4 starts after UTERM-015 M4. M1's gate on the filing became the declaration check, and the risk names UTERM-015.
- 2026-11-03: Scheduled as UTERM-006 M1-M3 and UTERM-006 M4 in queue.md.
- 2026-11-05: Messages shown while an image is on screen go to the status bar, after a status bar audit. The text said
  "with a message" or "the pane says" without a place. The refused drops, a deleted file reached while stepping, the
  stopped slideshow, and the zoom limit now post warnings. A folder that cannot be listed posts once and shows a
  "Folder not listed" warning segment while it holds. The pane keeps the image in each case. This follows the rule the
  user set for the map and data viewers. The 2026-11-03 marker on "Input sources" is replaced by this one.
- 2026-11-07: (work-queue best guess) Supported types: the helper's list is kept to types that conform to `public.image`,
  and the open panel and folder listing use that conformance until the helper answers. This narrowed the Rendering
  bullet that said the set is whatever ImageIO reports. It keeps PDF unopened, which an M1 check requires.
- 2026-11-07: (work-queue best guess) Values no document set. The per-helper footprint cap is 1 GiB. The app-wide helper
  budget is the smaller of 4 GiB and a quarter of RAM, with a 256 MiB floor per pane. The bitmap budget is the smaller of
  1 GiB and a quarter of RAM, with a 256 MiB floor per pane. The decode time bound is 10 seconds. The applet menu is
  titled "Image Viewer" and its command IDs are `image-viewer.<name>`. The launcher lists the image viewer last. The
  sandbox comes from an entitlements file outside `App/` with the build setting unset, which is the first of the two ways
  the sandbox check allows. The shipped helper proves its sandbox with a debug-only probe mode.
- 2026-11-07: ADR candidate (cuts across the system): the app runs outside the App Sandbox, and a helper that needs no
  file or network access runs inside it, with `check-sandbox-off.sh` guarding both. Undecided. Found in UTERM-006 M1.
- 2026-11-07: (work-queue best guess) Play or Pause Slideshow is one command, since a registry command has one title and
  the registry keeps no per-command state. This narrowed the Navigation bullets that said Play Slideshow toggles to Pause
  Slideshow. The status segment shows whether it plays.
- 2026-11-07: (work-queue best guess) A listing in progress keeps images in arrival order, with each batch ordered within
  itself, and takes the chosen order when the scan ends. A folder opened fresh shows the first image of its first batch.
  This narrowed "stable order while it runs" and "first image", which cannot both hold for a folder larger than one
  batch. The first image shown may differ from the first in Finder order until the scan ends.
- 2026-11-07: (work-queue best guess) A step to an image the pane already holds a decode of, the previous or the
  prefetched one, shows that decode without opening the file. A file deleted since the listing is found at the next step
  that needs it. This narrowed "a file deleted since the listing is skipped when reached". Checking the file first would
  put a disk call on the step's path, on a mount that may stall. The marker on that bullet replaces the 2026-11-05
  marker, whose folder-not-listed text the bullet now carries.
- 2026-11-07: (work-queue best guess) Restore of a single file shows the stored current image of the file's folder. When
  the file and its bookmark are gone, it opens the current image in the file's old folder, makes the stored path that
  image, and says where it found it. The restore chain was path, then bookmark, then the old folder, and the last step
  needed this reading for the stored path.
- 2026-11-07: (work-queue best guess) The image helper keeps up to four opened sources, with no protocol change, so a
  prefetch can open the next image beside the one on screen. The alternative was a close message and a version bump.
- 2026-11-07: (work-queue best guess) An animated image does not zoom, and the zoom commands are off for it. The
  helper decodes animation frames at fit size and cuts tiles from frame 0 only, so a zoom would show blur or the wrong
  frame. This narrowed the Zoom bullet and the M3 bullet that listed free zoom for any image. Zooming an animation needs
  tiles per frame inside the bitmap budget, which is its own design.
- 2026-11-07: (work-queue best guess) The decode level is the smallest power-of-two fraction of native that is not below
  the device resolution, capped at native. The Zoom bullet said the decode scale is the smaller of the zoom and native
  1:1. An exact scale would ask the helper for a new full decode on every pinch step. A level can be up to twice the
  device resolution, which the layers minify.
- 2026-11-07: (work-queue best guess) A refused zoom, or a zoom whose tiles fail, goes back to the last zoom that showed
  tiles, or to fit when there is none. The Zoom bullet said only that the zoom is refused. The marker on that bullet
  replaces the 2026-11-05 marker, whose status bar text the bullet still carries.
- 2026-11-07: (work-queue best guess) Values no document set. Zoom In and Zoom Out double and halve the scale, and a step
  that would pass actual size stops on it. The most an image magnifies is 32 device pixels per image pixel. A tile is 512
  pixels, and the pane keeps one ring of tiles around the viewport. Actual size uses the horizontal resolution for both
  axes. A file that declares none shows at 72 dots per inch. Arrows pan by a fifth of the pane.
- 2026-11-07: (work-queue best guess, addition) A double tap on a trackpad toggles between fit and actual size. No check
  or decision names it. It is UI polish that CLAUDE.md allows building directly. The user may drop it by removing the
  smart-magnify handler.
- 2026-11-07: (work-queue best guess, addition) While the image is zoomed, the status bar shows the zoom as a percent of
  actual size. No check or decision names it, and the UI tests read it. The user may drop it by removing the segment.
- 2026-11-07: (work-queue best guess) A step or a resize that arrives while the first tile of a level is in flight waits
  for it. That tile includes the whole decode of the level, which the helper cannot cancel short of a kill. The wait is
  bounded by the decode time bound, and by about 0.3 s for a 6000 by 4000 PNG in a debug build. A decode in flight was
  already uncancellable for stills, so this adds no new class of wait. A step does replace every waiting tile.
- 2026-11-07: (work-queue best guess) The helper draws a tile level at exactly the size the app computes, with one
  shared function, and the app accepts only a tile of exactly the rectangle it asked for. ImageIO's own thumbnail size
  differs from the app's by a pixel for many sizes, so the two disagreed at the edge.
- 2026-11-07: (work-queue best guess) The image protocol moved to version 2. The helper reports each source's resolution
  and answers region and release messages, since the app may not read image properties and the helper holds the decode
  that tiles come from. The helper ships in the same bundle, so no skew applies, and the handshake still refuses a
  mismatch with the message to relaunch uniterm.
- 2026-11-07: (work-queue best guess) Zooming past fit stops a playing slideshow, as a manual step does. The Navigation
  bullet said only that a manual step stops it. A tick that stepped away from a zoomed image would have discarded the
  detail the user zoomed in to see within 5 seconds. Zoom is a manual action, and the proposal had no rule for it. This
  amended the Navigation slideshow bullet, which keeps its single 2026-11-07 marker. A pinch reports its viewport only
  when the fingers lift, so the start of a pinch stops the show.
- 2026-11-07: An animated image zooms, with each frame decoded at the zoom's decode scale and capped at 1:1, so the
  zoomed animation keeps playing with sharp detail. This was the user's choice in a hands-on review. It replaces the
  work-queue best guess above that animations stay at fit, whose reason was that tiles are cut from frame 0 only. The
  Zoom bullet on the commands keeps its single 2026-11-07 marker, with its text replaced. The Zoom refusal bullet, a
  new Zoom bullet on animations, M3's first, refusal, and detach bullets, and the M3 As built bullet that kept
  animations at fit are amended to match. The new animation bullet, M3's detach bullet, and both refusal bullets
  carry the marker. The
  refusal bullets said the helper cap and the app-wide helper budget refuse a zoom, and that it goes back to the last
  zoom that showed tiles. They now add the bitmap budget, and the return to the last zoom whose whole window of frames
  was held, for an animation. The user turned down three alternatives: pause the animation and tile its current
  frame, magnify the fit-size frames, and keep animations at fit. The first needs a frame-aware tile path and loses
  the motion. The second is blurry, and the third drops the commands the viewer declares. Cost scales with frame size
  times zoom, and the bitmap budget and the per-helper cap bound it. A zoom past either is refused as a still's is.
  Whole frames at the level were built, not viewport regions of frame N, since a region needs a new message and a
  per-frame level in the helper. The protocol stays at version 2. Region frames are the next step if whole frames
  prove too big in use.
- 2026-11-07: (best guess under that choice) A refused or failed zoom of an animation goes back to the last zoom whose
  whole window of frames was held, or to fit. A zoom whose first frame fit and whose next did not is not a zoom that
  worked. The level an animation decodes at is used only when it is larger than the fit-size frame, so a small
  animation that already shows at native size asks for nothing new. The view magnifies zoomed frames with
  nearest-neighbor sampling, as it does tiles.
- 2026-11-07: ADR candidate (cuts across the system): the app runs outside the App Sandbox, and a helper that needs no
  file or network access runs inside it. Written as ADR-10, proposed. It stays proposed until UTERM-003's Janet helper
  shows whether the rule needs more nuance. The user's choice. Accepted on 2026-11-09, with the nuance that helper
  showed.
- 2026-11-07: The double tap that toggles fit and actual size, and the zoom-percent status segment, are kept. The
  user's choice after a hands-on review. Both were logged above as additions.
- 2026-11-07: (best guess) The double tap did nothing in the user's hands-on check. It now zooms to actual size around
  the pointer. When an image already shows at actual size at fit, it steps in once, as Zoom In does. A second double
  tap returns to fit.

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, APPLET-5
- ADR-10
