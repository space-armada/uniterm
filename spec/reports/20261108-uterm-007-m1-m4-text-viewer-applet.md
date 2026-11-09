# UTERM-007 M1-M4: Text viewer applet work-queue run

Started 2026-11-08. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-007 M1-M4`, from `spec/proposals/UTERM-007-text-viewer-applet.md`. UTERM-007 adds a read-only document
pane. PDFs render in-process through PDFKit. RTF and Word decode in a new sandboxed helper. Markdown renders in an
isolated web view. The specs live in the code repo, so every commit below is in this repo, on the `agent/petunia`
branch.

## Run state

UTERM-007 M1 to M4 are `DONE`, and the row moved to `history.md`. The proposal stays `accepted`, because M5 waits on
UTERM-004 M3 in its own row. The final review ran over the whole run.

Before M1, the user asked for the branch to be rebased onto main. Local `main` matched the fork's `origin/main`, which
the branch already held, so the run rebased onto `upstream/main` at "Merge pull request #37 from
ripta/agent/petunia-land/scroll-flake". The commits already upstream dropped out. "Wait for the reloaded title in the
browser recovery test" dropped too, since its patch was already upstream. The run's base, and the row's base, is
"Allowlist debugging commands in cg".

The row has no dependencies, and no milestone carries a `Live after` line. Nothing is held, blocked, or skipped, and no
work is stashed. No commands need the user's credentials.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-007 M1: PDF and RTF | DONE | "Add a text viewer for PDF, RTF, and Word documents" |
| UTERM-007 M2: Markdown | DONE | "Render Markdown in the text viewer inside an isolated web view" |
| UTERM-007 M3: Live reload | DONE | "Reload the text viewer when its file changes on disk" |
| UTERM-007 M4: Find and contents | DONE | "Find text and list contents in the text viewer" |

## Local checks

The implementer runs `make fmt-check`, `make lint`, `make check`, `make build`, and `make test-package` through
`cg_run`. It adds `make swiftpm-offline-check` when `Package.swift` changes, and `make fuzz` in M1. Then it runs
`proposals.py check` and `proposals.py freeze`.

The coordinator runs the checks that need a shell outside the agent sandbox: `make test-helper-sandbox`,
`scripts/check-sandbox-off.sh` on the built app, and the text viewer's UI tests. After UI runs it checks the
crash-report folder.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. M1 builds the shared helper infrastructure, since UTERM-006 landed first and left its helper code image-specific.
   The framing, byte coding, spawn, reap, footprint, and watchdog code move into helper-neutral targets, and the image
   viewer is rebased onto them. This rests on UTERM-007 "RTF and Word use the system readers" and M1's shared-bundling
   check. If wrong, the document helper would copy the image code instead.
2. The file descriptor goes with each decode request over `SCM_RIGHTS`, as the shipped image helper does. The proposal
   says "passed at spawn". M1 amends that text to match.
3. The document helper starts with only the App Sandbox entitlement. If the readers need an entitlement that
   `check-sandbox-off.sh` forbids, that is an ADR-10 conflict and blocks the row. The first fallback is decoding without
   the denied service, recording what is lost.
4. The per-helper footprint cap is 1 GiB and the decode bound 10 seconds, following UTERM-006. M1 picks the byte,
   length, table cell, image count, and pixel caps and records them in the Decision Log.
5. The open, `fstat`, and capped read move into `SourceAccess`, shared by the image, map, data, and text viewers.
6. M3 moves the map viewer's `FileWatcher` into a shared target and adds a parent-folder watch.
7. The sanitizer allowlist is GitHub's published README allowlist at a recorded version, minus entries that need the
   network.

## Base check

After the rebase, `make build` passed (cg run `3SVVWB`). `make test-package` passed (cg run `F6M6QT`): 1,767 tests,
5 skipped, 0 failures, in 130 s.

## UTERM-007 M1: PDF and RTF

### Commits

- "Add a text viewer for PDF, RTF, and Word documents". The review fixes and this report's M1 section are in the same
  commit.

### What landed

- The image helper's framing, byte coding, spawn, reap, footprint, and watchdog code moved into the helper-neutral
  `HelperWire` and `HelperHost` targets. The image viewer runs on them. Its tests changed only in imports and one call
  signature, and its entitlements are unchanged.
- A new sandboxed `DocumentDecoder` helper runs the system RTF and Word readers. Each decode starts its own helper and
  ends it with the decode. The reply is a secure-coded attributed string, with images as raw pixels outside the
  archive.
- The open, `fstat`, and capped read moved into `SourceAccess`. The image, map, and table readers use it now.
- The text viewer applet: PDF in-process through `PDFDocument(data:)`, RTF and Word through the helper, restore with
  the bookmark fallback, the launcher entry on Cmd-7, the router's type declarations, and `Info.plist` document types.
- PDF fuzzing and wire fuzzing joined `make fuzz`.

### Checks

| Check | Run | Result |
|---|---|---|
| `make fmt-check`, `make lint`, `make check` | FEA4XK, YSQ28M, 3YCM8B, then T5458E, CBF7AA | pass |
| `make build` | XKPPM4 | pass |
| `make swiftpm-offline-check` | 017HM6 | pass |
| `make fuzz FUZZ_ITERATIONS=500` | DM4733 | pass |
| ASan, 20,000 iterations each of `PDFFuzzTests` and `DocumentWireFuzzTests` | KADYDH | no crash, hang, or sanitizer report |
| `make test-helper-sandbox`, coordinator, outside the agent sandbox | W1DF54 | 6 tests, 0 failures |
| `scripts/check-sandbox-off.sh` on the built app | implementer's run | pass |
| `log show` over the sandbox test window | XVHAA4 | no denials for the reader decodes |
| Text viewer UI tests, first run | D3XZHY | 4 of 4 failed: the pane view was not an accessibility element |
| Text viewer UI tests, after the fix | S3C4E6, then J5XM3X | 4 tests, 0 failures |
| `make test-package`, coordinator, before commit | BKHBHC | 1,867 tests, 7 skipped, 0 failures, 123 s |
| `proposals.py check` and `freeze` | R1NE76, SVENE2 | `[]` |

The coordinator looked at three screenshots from J5XM3X: the empty state, a loaded PDF, and a restored RTF. The RTF
came through the sandboxed helper with its 26 pt heading, bold run, and bordered table intact. The PDF page fills the
pane, and the status bar reads "Page 1 of 2".

The sandboxed helper needed no sandbox operation beyond the default App Sandbox profile on this macOS. The log showed
"AppSandbox request successful" for each `DocumentDecoder` spawn. Its only denials were the probe's intended file read
and network connection.

### Best guesses

Each is a Decision Log entry tagged as a work-queue best guess.

- The descriptor travels with each decode request over `SCM_RIGHTS`. The proposal said "passed at spawn" and was
  amended to match the shipped image helper.
- Each RTF or Word decode starts its own helper and ends it. This meets "no helper outlives its pane" and "undo-reopen
  starts a fresh one" without a per-pane helper to manage.
- Caps: a PDF reads up to 256 MiB. An RTF or Word file passes up to 64 MiB. A decoded document holds up to 4,000,000
  UTF-16 characters, 20,000 table cells, and 64 images. Each image is up to 16 Mpx, and all images together up to
  64 Mpx. The archive is up to 32 MiB. The footprint cap is 1 GiB and the decode bound 10 s, as in UTERM-006. If the
  caps are wrong, they change in `TextViewerLimits`.
- The format rule reads names only. `README` with no extension and the Markdown extensions map to Markdown. M1 does not
  declare Markdown, so Cmd-O never routes a `.md` file to a viewer that cannot show it yet. M2 adds the declaration.
- The document page stays white with the document's own text colors in every theme. The theme colors the surround,
  the PDF background, and the messages.
- The text view uses TextKit 1, since only TextKit 1 draws `NSTextTable`.
- A file behind macOS privacy protection fails with the data viewer's permission message. The system's own consent
  dialog was not exercised.

### Review findings

| Finding | Disposition |
|---|---|
| A restored pane's `describe()` never left the restored payload, so scrolling after reopen was not saved (CONFIRMED) | Fixed. A regression test failed on the old code. The fix exposed a second bug: non-contiguous layout moved the RTF scroll target. `scrollText` now lays out through the target first |
| The "sandbox operations recorded" check was unmet and the As built was stale | Fixed with the W1DF54 and XVHAA4 evidence |
| PDF link filtering rested on an unverified delegate behavior (PLAUSIBLE) | Traced. `PDFView.h` says the delegate's link method replaces the default `openURL:`. Other PDF actions now pass through a filter in `perform(_:)` that runs only page navigation, safe-scheme links, and named actions other than print. No test drives a real click |
| The Dependencies line still said "whichever lands first" | Fixed with an amendment |
| As built said the image viewer's tests were unchanged | Fixed: imports and one call signature changed, no assertion |
| The readers returned no embedded pictures in any sample | Left for the user. See below |

The ADR-impact pass found no conflicts. It raised two candidates. Neither passed the Architecture test:

- The shared helper layer is a mechanism. The invariant behind it is ADR-07 and ADR-10.
- PDF in-process is the per-design exception ADR-07 already asks a design to justify, and the proposal does.

### Left for the user

- On this macOS, the RTF, Word 97, and Word XML readers returned no picture attachment in any sample, including a
  hand-built `.docx` with an inline PNG. So "embedded images arrive as bitmaps within the pixel caps" is proved only
  with attachments built in code. Decide whether that meets the check, or whether a real document with pictures should
  be tried.
- Word rendering fidelity against Word or Pages.

### Unowned failures

None. Each launcher UI test logs two AutoLayout conflicts from `LauncherView` at zero size. That is existing launcher
code, and no test fails on it.

### Test cost

| Class | Wall time alone |
|---|---|
| `TextViewerAppletTests` | about 1.1 s |
| `DocumentHelperTests` | about 2 s |
| `DocumentHelperServerTests` | 5.06 s before a teardown fix, not re-timed |
| `HelperSandboxTests` for the text viewer | under 1 s |
| `PDFFuzzTests` at 500 inputs | 0.19 s |
| Other new classes | under 0.2 s each |
| `TextViewerUITests`, 4 tests | 34 s |

The package suite went from 1,767 tests in 130 s to 1,867 tests in 123 s.

## UTERM-007 M2: Markdown

### Commits

- "Render Markdown in the text viewer inside an isolated web view". The review fixes, the shared open-panel helper,
  and this report's M2 section are in the same commit.

### What landed

- markdown-it 15.0.3 and DOMPurify 3.4.17, pinned by version and sha256 in `web-assets.pin`.
  `scripts/fetch-web-assets.sh` reproduces them byte for byte from the npm registry, and a package test hashes the
  shipped files against the pin. The sanitizer allowlist follows `gjtorikian/html-pipeline`'s sanitization filter at
  a recorded commit. `make licenses` collects both notices.
- Each Markdown pane gets its own web view with a non-persistent store and page JavaScript off. The parser, sanitizer,
  and viewer scripts run in one named content world, with one message handler there. A scheme handler serves the page,
  the text, and relative images. A CSP header and a content rule list each block every load outside the scheme. With
  the sanitizer bypassed in a debug build, either one alone stopped every request.
- Relative images resolve through a new device-checked walk, `ConfinedFile`. It refuses mount points, automount roots,
  devices, and FIFOs.
- Scroll anchors come from markdown-it's token map, held in the isolated world. No DOM attribute is read.
- Messages from the page carry a page generation, and the host drops stale ones.
- A content-process crash shows a message with a Reload button.
- `App/Info.plist` imports `net.daringfireball.markdown` with its extensions, since `.md` resolved to another app's
  `com.unknown.md` on this machine and the router matches by type conformance only.

### Checks

| Check | Run | Result |
|---|---|---|
| `make fmt-check`, `make lint`, `make check` | 1GKPHV, Q9QKYB, 58N0KN, then 9BZ4ZR, 4AG299 | pass |
| `make build` | 4V0AF4 | pass |
| `make swiftpm-offline-check` | ZXSKYE | pass |
| `make licenses` | 8TRR7X | pass, only the new notices changed |
| `proposals.py check` and `freeze` | JQ5T5T, 9M9QTC | `[]` |
| Text viewer UI tests, first M2 run | K49RR0 | 6 tests, 0 failures. The screenshot showed a closed `<details>` leaking its body |
| Text viewer UI tests, after the review fixes | 7HHRBQ | 1 failure: the PDF open-panel test typed its path. See "Unowned failures" |
| Text, data, image, and map viewer UI tests, after the shared paste helper | M5G46B | 36 tests, 0 failures |
| `make test-package`, coordinator, before commit | SAKK8J | 1,909 tests, 7 skipped, 0 failures, 207 s |

The coordinator looked at the light and dark README screenshots, and at the restore screenshot. The heading and the
image are centered, and the code block and the table render. Theme colors follow the uniterm theme. The closed
`<details>` hides its body after the fix. The restored README lands at Section 94 for its stored line 400.

Before each UI run, the coordinator checked the other sessions' running commands by directory. They were elastane's
CLI tests and nitipan's Go `make ci`, and neither uses the screen. After each run, the crash folder held only the
helpers' fault-injection reports from package tests and another project's reports.

### Best guesses

Each is a Decision Log entry tagged as a work-queue best guess.

- The payload stays at version 1, with the Markdown anchor fields optional. No reader outside this branch has seen a
  version 1 payload.
- The CSP also allows `style-src` and `connect-src` for the viewer's scheme only, since the page fetches its text and
  stylesheet from it.
- A Markdown file reads up to 32 MiB, and one image up to 16 MiB.
- Sanitizer narrowings against GitHub's list: `longdesc` dropped, `srcset` only on `<source>`, and links limited to
  `http`, `https`, and `mailto`. Task-list checkboxes render as text, since `input` is off the allowlist.
- A raw-HTML element left open by one Markdown block groups the following blocks until it closes, up to 400 blocks,
  and the group is sanitized as one unit. That is what keeps a `<details>` body inside its element.
- The rule list compiles into WebKit's default rule-list store. A failed compile fails closed with a message, and the
  next pane compiles again.
- Reload has no key or registry command in M2. M3 binds Cmd-R.
- M2's check "After a scroll and an immediate layout save, reopen lands on that scroll position" was amended. A save
  taken after the page's scroll report arrives, one message after the scroll, reopens there. `describe()` is
  synchronous, so a save in the same turn as the scroll cannot hold the new position.

### Review findings

| Finding | Disposition |
|---|---|
| A closed `<details>` showed its body (coordinator, from the screenshot) | Fixed. Each block was sanitized alone, which closed the element early. A test failed on the old code |
| The immediate-save check was not met as written | Narrowed: the anchor pushes from the scroll handler. Check amended, as above |
| `.md` files may not route by type | Traced: the router matches by conformance only. Fixed with the type import. Whether Launch Services prefers uniterm's import over another app's claim is not provable in tests |
| A failed rule-list compile was cached until relaunch (CONFIRMED) | Fixed, with a test of the injected compiler |
| Payload bumped to version 2 | Reverted to version 1, and the Decision Log entry corrected |
| Scheme tasks keyed by object identity could be answered by a stale read (PLAUSIBLE) | Fixed with a per-request serial. Not reproduced |
| Page messages carried no generation (PLAUSIBLE) | Fixed. A test feeds stale messages |
| Test-only hooks on the scheme handler | Removed. The tests observe image loads through rendered image sizes |

The ADR-impact pass found no conflicts. One candidate passed the bar and is in the Decision Log as Undecided: a path
named by a document's content never leaves the document's volume and never triggers an automount. The second, the web
view lockdown for untrusted markup, has one consumer today, so it stays in the proposal.

### Left for the user

- A real file drag onto rendered Markdown. Only the drag registration is tested.
- Whether `.md` files route to the viewer through Finder or Cmd-O on a machine where another app claims `.md`.

### Unowned failures

`testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAPDF` failed once in 7HHRBQ: "the go-to-folder sheet never closed".
Typing the path took 12 s against about 2.5 s in passing runs. The test, written in M1, typed the path into the open
panel. `spec/flaky-tests.md` records the same flake as fixed for the data viewer by pasting. The paste helper moved
into `UnitermUITestCase`, and the text, data, image, and map viewer tests all use it now. The four classes then passed
together in M5G46B. One clean run does not prove the fix. It rests on the data viewer's earlier diagnosis.

### Test cost

| Class | Tests | Wall time alone |
|---|---|---|
| `ConfinedFileTests` | 6 | 0.005 s |
| `MarkdownPureTests` | 6 | 0.006 s |
| `MarkdownViewTests` | 16 at first count | 9.8 s, about 4 s of it the 20 MB test |
| `MarkdownAppletTests` | 7 at first count | 1.4 s |
| `TextViewerUITests` | 6 | 48 s |

The 20 MB test is the only package test over 2 s. It proves a stated milestone check that no cheaper layer can show.
It rendered in 3.75 s in SAKK8J, with a longest main-thread gap of 0.025 s.

The package suite took 207 s in SAKK8J, against 123 s after M1. 60 s of that is two `BrowserDownloadCancelTests`
cases, `testACancelWithNoByteYetWaitsForOne` and `testADeferredDownloadThatFailsFirstCleansUpQuietly`, at 30.1 s each.
Both passed. The same code took 0.08 s and 0.09 s for them in the implementer's T8BTYF. Run alone in 1FBDJX, the class
took 1.5 s. The 30 s looks like a wait running out its time bound, not slow work. SAKK8J ran right after a 36-test UI
run, while two other sessions ran CI. The cause is unresolved. M2 changed no browser code.

## UTERM-007 M3: Live reload

### Commits

- "Allow caffeinated test runs in the cg allowlist". The user chose narrow rules at a prompt during M3.
- "Reload the text viewer when its file changes on disk". The review fixes, the PDF placement fix, the flaky-test entry,
  and this report's M3 section are in the same commit.

### What landed

- A new `FileWatching` target replaces the map viewer's private watcher. It watches the file and its parent folder. A
  folder event counts only when the path's device, inode, size, or modification time changed. A gone path is looked at
  every 0.5 s, then every 5 s. All `stat` and `open` calls run on a worker queue, so the main thread never waits on a
  user path. The map viewer keeps its old behavior through a file-only policy.
- The text viewer reloads on change. A burst settles for 0.15 s, and a continuously rewritten file reloads at most once
  a second. A reload swaps in only on success and keeps the source anchor. A failed reload keeps the render and posts
  one warning. A gone file keeps the render and shows a "Moved or deleted" segment until it returns. Changes made
  while detached reload once at reattach. `close()` stops the watch.
- Reload is a registry command on Cmd-R, in the View menu.
- A PDF with no anchor now starts at the page top in every case. Before, PDFKit landed about 93 points down page 1
  when the view already had a size.

### Checks

| Check | Run | Result |
|---|---|---|
| `make fmt-check`, `make lint`, `make check` | E02KH9, 9RVR1A, 336NBK | pass |
| `make build` | K1FTY7 | pass |
| `make swiftpm-offline-check` | DX3N4Z | pass |
| `xcodebuild build-for-testing` | QYP4G6 | pass |
| `caffeinate -dimsu make test-package`, implementer | 7S5KAB | 1,939 tests, 7 skipped, 0 failures |
| `proposals.py check` and `freeze` | implementer's last runs | `[]` |
| Text and map viewer UI tests under caffeinate | 7R1JEH | 16 tests, 1 failure in `MapViewerUITests`. See "Unowned failures" |
| Map viewer UI tests alone | ZQ5SK2 | 8 tests, 0 failures |
| Text viewer UI tests after the placement fix | H16R24 | 8 tests, 0 failures |
| `caffeinate -dimsu make test-package`, coordinator, before commit | ZV2CPR | 1,939 tests, 7 skipped, 0 failures, 223 s |

The coordinator looked at the deleted-file screenshot twice. In 7R1JEH the render stayed and the segment showed, but
the restored PDF's first line was clipped at the top. After the placement fix, H16R24 shows the page top with its
margin.

### Environment: an idle display

Full package runs between 17:00 and 20:00 local failed 115 tests in `MarkdownAppletTests`, `MarkdownViewTests`, and
`ImageViewerScrollTests`. That covers the implementer's runs and the coordinator's KKWE67 at 1,936 tests. Every one of
these classes had passed in SAKK8J at 16:25 on the M2 commit. A pristine copy of the M2 commit failed the same way.
Both displays reported full power. The user was away, and the user suggested `caffeinate`. Under
`caffeinate -dimsu`, the full suite passed in EFASF3 and 7S5KAB. Test runs now use `caffeinate -dimsu`, and
`.cg.yaml` allows that for `make test-package`, `make test-app`, `swift test`, and `run-ui-tests.sh`.

The implementer's first `caffeinate` call waited about 26 minutes on an approval prompt, because `caffeinate` was not
allowlisted. A pending cg call missing from `cg_list` gave it away.

After the coordinator's commit, the user replaced the `swift test` rule with `wrapper: [caffeinate, -dimsu]`. That edit is
the user's, and the run leaves it uncommitted. The coordinator first misread it mid-edit as a typo.

### Best guesses

Each is a Decision Log entry tagged as a work-queue best guess.

- The shared watcher is a new `FileWatching` target, since `SourceAccess` stays Foundation-only.
- The settle is 0.15 s and the ceiling 1 s.
- The text viewer looks for a gone path for as long as the pane lives. The map viewer keeps its ten looks.
- A watcher event during a load queues one reload after it, so a continuously rewritten RTF or Word file cannot starve.
  Cmd-R and opening another file still end the running helper first.
- A file that is found but fails its first load keeps the watch, so fixing the file reloads it. A path that cannot be
  found starts no watch, and Cmd-R covers it.
- A PDF rewritten in place now reloads. The guarantee is that one load is one full read, and no mapped or lazy file
  backs the view. A failed parse keeps the old render. A truncated PDF may still parse, and the next write reloads
  again. "The applet contract" and M1's PDF check were amended to say so.

### Review findings

| Finding | Disposition |
|---|---|
| A file deleted and then back with bad content kept the "Moved or deleted" segment and hid the failure (CONFIRMED) | Fixed. A regression test failed on the old code |
| As built said a failed first load starts no watch | Fixed: the text now matches the code, and a test pins it |
| The amendment promised a half-written PDF never reaches PDFKit | Reworded to the real guarantee |
| M1's rewritten-PDF test proved nothing about reload | Rewritten to prove the view is not backed by the file |
| Watchers leaked from tests that never close their pane (PLAUSIBLE) | Fixed: `FileWatcher` stops in `deinit`, and the harness defaults to a silent watch |
| Real-time sleeps in absence checks, and overlapping tests | Replaced with an injected scheduler and counters. One overlapping applet test was dropped |
| `stat` and `open` ran on the main thread, with a forever poll (ADR-08, adr-impact) | Fixed: a worker queue does the file-system calls |
| A comment wrapped with an orphan line | Fixed |
| A restored PDF with no anchor was clipped at the top (coordinator, from the screenshot) | Fixed. A test failed on the old code. The anchored-restore and reload paths were already right, and a test pins them |

The ADR-impact pass found no conflicts beyond the advisory ADR-08 item. The shared watcher policy and the keep-the-last-
render behavior stay in the proposal.

### Unowned failures

In ZV2CPR, `BrowserDownloadCancelTests.testADeferredCancelEndsAfterTheGraceWhenNoByteComes` passed in 30.2 s. In
M2's SAKK8J, two other tests in the same class took 30.1 s each. Alone, the class takes about 1.5 s. A 30 s wait is
running out in full-suite runs, in a different test each time. The cause is unresolved, and no M1 to M3 change touched
browser code.

`MapViewerUITests.testCommandORoutesAGeoJSONFileToTheMapAndShowsItsPins` failed once in 7R1JEH with "no go-to-folder
sheet". The cg server restarted during that run. The class passed 8 of 8 alone in ZQ5SK2. It is listed under
"Potential" in `spec/flaky-tests.md`.

### Left for the user

- File events on a network volume, or a volume where events never arrive. Only Cmd-R covers that, and it is tested
  with the watch silenced.
- A rename of a folder above the watched folder is not detected. Cmd-R covers it.

### Test cost

| Class | Wall time alone |
|---|---|
| `FileWatcherTests` | about 1 s |
| `ChangeCoalescerTests` | about 2 ms |
| `LiveReloadTests`, 14 tests | about 3 s |
| `PDFPlacementTests` | not timed alone |
| `TextViewerUITests`, 8 tests | 81 s for the class |

## UTERM-007 M4: Find and contents

### Commits

- "Find text and list contents in the text viewer". The review fixes, the screenshot fixes, and this report's M4
  section are in the same commit. The report also carries the corrected `.cg.yaml` note under M3.

### What landed

- Find (Cmd-F), Find Next (Cmd-G), Find Previous (Cmd-Shift-G), and Use Selection for Find (Cmd-E) in Edit > Find, and
  Show Contents in View with no key. A catalog test pins the keys through the real registry and menu.
- One find bar per pane. The query lives in the pane. Nothing reads or writes the system find pasteboard, and the
  text, PDF, and web views hand their built-in find actions to the pane.
- RTF and Word search a copy of the text off the main thread. PDF uses PDFKit's asynchronous find. Markdown searches
  in the parser's isolated world, with the query passed as a call argument.
- Matching is case- and diacritic-insensitive in every format. The page mirrors Foundation's fold, and a hit counts
  only when it starts and ends on source-character boundaries.
- A contents sidebar from structure only: the PDF outline, Markdown headings, and RTF/Word heading levels. Lists are
  capped by entry count and depth, and the sidebar says why one was cut. Its visibility persists in the description.
- The current PDF match, and a PDF outline jump, land with room above them. The current Markdown match is the
  strongest highlight.

### Checks

| Check | Run | Result |
|---|---|---|
| `make fmt-check`, `make lint`, `make check` | TSSKBA, 46EY0Y, 63SD90 | pass |
| `make build` | 22C85P | pass |
| `xcodebuild build-for-testing` | E21HG4 | pass |
| `caffeinate -dimsu make test-package`, implementer, after the last change | YENFAQ | 1,975 tests, 7 skipped, 0 failures |
| `caffeinate -dimsu make test-package`, coordinator, before the screenshot fixes | SFS1C5 | pass |
| `proposals.py check` and `freeze` | implementer's last runs | only the row-to-history finding, and `[]` |
| Text viewer UI tests, first try | EP3ZMT | did not start: the automation authentication prompt was cancelled |
| Text viewer UI tests | JRTZ8F | 11 tests, 3 failures: two sidebar lookups, and one hang on a system dialog |
| Text viewer UI tests | 9C11WD | 13 tests, 2 failures: the sidebar lookups |
| Text viewer UI tests | QYTAYX, MJE1AA | 13 tests, 0 failures |
| Text viewer UI tests, after the Use Selection fix | KJT03V | 13 tests, 0 failures |

The coordinator looked at every screenshot across those runs and sent back each visual problem:

- The current Markdown match was paler than the others.
- The current PDF match sat under the find bar.
- One screenshot captured other applications' windows instead of uniterm.
- Selected sidebar text was dark on blue.
- A PDF outline jump clipped its target.
- An empty strip sat at the bottom of the sidebar.
- Use Selection reported no matches for the selected text.

KJT03V shows all of them fixed. Use Selection on the RTF finds "A sample document", 1 of 1, and selects it.

### Best guesses

Each is a Decision Log entry tagged as a work-queue best guess.

- Matching follows Foundation's case- and diacritic-insensitive rules in every format. Matches are capped at 10,000
  and queries at 500 characters.
- A match inside a closed `<details>` counts, and opens that element only when it becomes current.
- A typed query selects the first match. A reload searches again without moving the view.
- Use Selection takes the selection's first non-empty line or table cell, and the match inside the selection becomes
  current. PDFKit, Foundation, and the page do not match across line breaks the same way, so a joined query could not
  match consistently.
- Show Contents stays enabled while the sidebar is shown, so a sidebar left open can be hidden when the next document
  has no outline. M4's check text was amended for this.
- Contents are capped at 5,000 entries, depth 32, and 200-character titles. Markdown entries scroll by heading index.

### Review findings

| Finding | Disposition |
|---|---|
| Markdown matched inside a character that expands when folded, such as "s" in "ß" (CONFIRMED) | Fixed: hits must fall on source-character boundaries. The agreement test failed before the fix |
| The reload test passed even with the generation check removed (CONFIRMED) | Fixed. It now fails without the check |
| No test covered Markdown Use Selection | Added |
| Proposal hygiene: two amendment markers on one decision, long lines, a reason in As built | Fixed |
| The cap test bypassed the pane's own find | Now drives the pane and counts main-actor turns |
| The outline walker keyed visited nodes by address, and the cut message ignored its cause | Fixed: the walker retains nodes, and the message names the cause |
| `PDFSearch.active` could be read off the main thread (PLAUSIBLE) | Traced: the reads were already on main. It is now `@MainActor`, so the compiler enforces it |
| Real-time sleeps and polling in tests | Replaced with awaited completions |
| A long doc comment | Rewrapped |
| Use Selection could apply a stale selection after a reload | Fixed with a generation check |

The ADR-impact pass found no conflicts. Its pasteboard candidate was already declined on 2026-11-03, since CLAUDE.md
"Applet Attributes" states it. Its other candidates are specific to this viewer.

### Left for the user

- Real RTF and Word files get no contents on this macOS. The system readers set no heading level, even for a `.docx`
  with Heading 1 and 2 styles, or an RTF with `\outlinelevel`. The code lists headings when levels are present, and a
  test proves that with text that carries levels. The proposal lists this as left undone, and the Decision Log holds
  an unowned finding.
- Every row in the contents sidebar reports "Disabled" to accessibility. So does the whole pane subtree, and that
  predates M4. The cause is unexplained.

### Unowned failures

- `TerminalSessionIntegrationTests.testClipboardReadIsNeverAnsweredWithoutConfirmation` failed once in the
  implementer's full run VBEE6A, with "timed out waiting for the second request". It passed alone in NWCXQW and in the
  next full run, WE06KH. No M4 change touches terminal code. The cause is unresolved.
- `testAnEditedFileReloadsInPlaceAndByRename` hung once in JRTZ8F. Its spindump shows the app idle and the runner
  inside `XCUIInterruptionMonitor`, handling a system dialog. It passed in every later run.

### Test cost

| Class | Wall time alone |
|---|---|
| `FindModelTests` | 0.01 s |
| `FindTests` | 1.5 to 2.5 s |
| `ContentsTests` | about 2.3 s |
| `TextViewerUITests`, 13 tests | 127 s for the class |

## Row review: UTERM-007 M1-M4

### Commits

- "Fix stale text viewer proposal notes and two bare test sleeps". It also carries this section.

### Findings

A holistic review of the range found no correctness or security defect. It traced every load path through one
`open()`, with a generation check after each `await`. It confirmed that `describe()` stays disk-free at version 1,
that the main thread is bounded, and that the shared infrastructure has no leftover duplicates.

| Finding | Disposition |
|---|---|
| M3 As built blamed the Markdown test failures on code before M3 | Fixed: the cause was an idle display, and the suite passes under `caffeinate` |
| M1 As built still said Markdown was undeclared | Fixed: past tense, until M2 declared it |
| M4 pair counts disagreed: 18, eight, and 28 in the test | Fixed: 28 in total, eight of them for matches inside a sharp s or a ligature |
| Two bare sleeps in `MarkdownViewTests` | The refused-image wait now polls until each image completes. The relative-link check now uses `settle()`, since the pane cancels that navigation silently and nothing signals it. The coordinator rejected a first version that relied on WebKit deciding navigations in click order |
| One Decision Log entry miscounted its amendment markers | Fixed |

The ADR-impact pass over the range found no conflicts. Its only open candidate, that document-named paths never leave
the document's volume, is already in the Decision Log as Undecided.

### Checks

| Check | Run | Result |
|---|---|---|
| `make fmt-check`, `make lint`, `make check` | 3Q4DRF, CJGGS3, GKGX9J | pass |
| `MarkdownViewTests` under caffeinate | EX6TKN | pass |
| `caffeinate -dimsu make test-package`, before the last test edit | Y63CGD | pass |
| `proposals.py freeze` with the row's commits | 0S1R2Y | `[]` |

`settle()` is now called three times, about 4.5 s in total.

## Final review

### Commits

- "Collect license notices for the packages bundled into markdown-it". It also carries this section and the run-state
  reflow.

### Findings

The final review covered the whole run. It found no blocking issue. `proposals.py check` and `freeze` both returned
`[]`. `queue.md`, `history.md`, and the proposal index agree. The web asset hashes match the pin, and no debug artifact
was committed. The range adds and edits no ADR file. The ADR-impact pass found no conflict. ADR-10 is honored by the
second sandboxed helper.

| Finding | Disposition |
|---|---|
| The markdown-it bundle inlines other packages whose notices were not collected (PLAUSIBLE) | Confirmed from the shipped source map: entities (BSD-2-Clause), linkify-it, mdurl, punycode.js, and uc.micro. Each is now pinned with its version and integrity, and its notice is collected into `Licenses/web-assets/`. DOMPurify bundles nothing |
| A 146-column Decision Log line, and a marker missing its period | Fixed |
| The report's run-state paragraph ran two thoughts together | Fixed |

The inlined packages' versions are a best guess. markdown-it publishes no lockfile, so each is the highest release its
dependency range allowed before markdown-it 15.0.3 was published. If the build used an older release, only a license
year or holder line could differ.

### Checks

| Check | Run | Result |
|---|---|---|
| `make licenses` | HWRXSM | pass |
| `make fmt-check`, `make lint`, `make check` | 1AC9PR, 0B9PCS, GCWKKQ | pass |
| `caffeinate -dimsu make test-package` | 1EG62R | pass |
| `proposals.py check` and `freeze` | K2YT8T, 2EGMNY | `[]` |

## The user's hand check

After the run, the user checked the viewer by hand in the running app.

| Check | Result |
|---|---|
| A web link in a PDF | Opens in the system browser, as the proposal decides |
| Saving from the user's own editor | The pane reloads and keeps its scroll. Deleting the file shows the status bar warning |
| Dropping a file onto rendered Markdown and onto a PDF | Opens the dropped file |
| Opening a `.md` file from Finder | Failed: uniterm launched and restored its panes but opened no pane for the file. `.md` resolves to another app's `com.unknown.md` here, and the router matches by type conformance only. Fixed after the run, with the user's choice of an extension-based fallback |
| Word and RTF files with pictures and headings | Not tested: the user had no such file |
| Find, Find Next, Find Previous, and Use Selection | Work in PDF and Markdown. RTF was not tried |
| Another app's find field | Never picked up the viewer's query, checked against Chrome and Mattermost |
| VoiceOver in the contents sidebar | Works |
| Theme switching with Markdown open | Works |
