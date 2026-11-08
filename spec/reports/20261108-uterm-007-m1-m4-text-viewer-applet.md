# UTERM-007 M1-M4: Text viewer applet work-queue run

Started 2026-11-08. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-007 M1-M4`, from `spec/proposals/UTERM-007-text-viewer-applet.md`. UTERM-007 adds a read-only document
pane. PDFs render in-process through PDFKit. RTF and Word decode in a new sandboxed helper. Markdown renders in an
isolated web view. The specs live in the code repo, so every commit below is in this repo, on the `agent/petunia`
branch.

## Run state

The run is in progress. Before M1, the user asked for the branch to be rebased onto main. Local `main` matched the fork's
`origin/main`, which the branch already held, so the run rebased onto `upstream/main` at "Merge pull request #37 from
ripta/agent/petunia-land/scroll-flake". The commits already upstream dropped out. "Wait for the reloaded title in the
browser recovery test" dropped too, since its patch was already upstream. The run's base, and the row's base, is
"Allowlist debugging commands in cg".

The row has no dependencies, and no milestone carries a `Live after` line. Nothing is held, blocked, or skipped, and no
work is stashed. No commands need the user's credentials.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-007 M1: PDF and RTF | DONE | "Add a text viewer for PDF, RTF, and Word documents" |
| UTERM-007 M2: Markdown | QUEUED | |
| UTERM-007 M3: Live reload | QUEUED | |
| UTERM-007 M4: Find and contents | QUEUED | |

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
