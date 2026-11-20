# Proposals

| Proposal | Description | Status |
|----------|-------------|--------|
| [UTERM-001](UTERM-001-foundation.md) | Windows, regions, pane tree, status bar, and the libghostty terminal applet | implemented |
| [UTERM-002](UTERM-002-command-palette.md) | Floating or docked command palette with tab search | implemented |
| [UTERM-003](UTERM-003-janet-scripting.md) | Embedded Janet, host API, `uniterm run`, and the REPL applet | implemented |
| [UTERM-004](UTERM-004-control-and-trust.md) | Pane control, durable controller trust, scoped approvals, and layout requests | implemented |
| [UTERM-005](UTERM-005-browser-applet.md) | WebKit browser applet with tabs and a security indicator | accepted |
| [UTERM-006](UTERM-006-image-viewer-applet.md) | Image viewer applet with folder slideshow | accepted |
| [UTERM-007](UTERM-007-text-viewer-applet.md) | Viewer for Markdown, RTF, Word, and PDF | implemented |
| [UTERM-008](UTERM-008-map-viewer-applet.md) | MapKit applet with custom pins | accepted |
| [UTERM-009](UTERM-009-data-viewer-applet.md) | Table viewer for CSV, JSON, and spreadsheets | implemented |
| [UTERM-010](UTERM-010-canvas-applet.md) | Canvas applet that programs draw on | draft |
| [UTERM-011](UTERM-011-widget-bar.md) | Widget bar region with small widgets | deferred |
| [UTERM-012](UTERM-012-shell-blocks.md) | Collapsible command blocks in the terminal | deferred |
| [UTERM-013](UTERM-013-shortcut-ownership-and-reopen.md) | Window versus applet shortcuts, and Cmd-Shift-T reopen | implemented |
| [UTERM-014](UTERM-014-palette-and-reopen-review-fixes.md) | Cmd-K palette, title bar dock, and reopenable exits | implemented |
| [UTERM-015](UTERM-015-cross-applet-file-opening.md) | Finder, File > Open, and other ways a file reaches an applet, and the path-reading power | implemented |
| [UTERM-016](UTERM-016-map-pin-editing.md) | Add, edit, and remove map pins by hand, and save them to GeoJSON | accepted |
| [UTERM-017](UTERM-017-status-bar-placement.md) | Where notices go, their levels, window status slots, and the shared queue | implemented |
| [UTERM-018](UTERM-018-open-in-nearest-capable-pane.md) | Every open walks to the nearest pane that can handle it | accepted |
| [UTERM-019](UTERM-019-browser-automation.md) | Controller scripts run JavaScript, follow page events, and send input in their own browser tabs | accepted |
| [UTERM-020](UTERM-020-inspector-bridge.md) | Console, network, interception, and debugging for controller tabs through a hidden Web Inspector | accepted |
| [UTERM-021](UTERM-021-declared-script-permissions.md) | Script files declare their powers, with strict mode by default and a lint | implemented |
| [UTERM-022](UTERM-022-questions-applet.md) | Scripts ask the user forms in a tabbed Questions pane, with live validation | accepted |
| [UTERM-023](UTERM-023-controller-runs-with-sip-off.md) | What uniterm does for controller runs on a Mac with SIP off | draft |
| [UTERM-024](UTERM-024-controller-input-channel.md) | Janet controllers declare palette commands bound to keys, and read the user's invocations | accepted |
| [UTERM-025](UTERM-025-presentation-controller.md) | Present a Markdown deck in a text viewer pane beside the terminal, stepped with the arrow keys or the palette | accepted |
| [UTERM-026](UTERM-026-screen-control.md) | Speaker notes in a presenter view, pane zoom, windows across displays, and Pop Out Pane | accepted |
| [UTERM-027](UTERM-027-controller-plain-keys.md) | Plain keys for controllers, folded back into UTERM-024 | retracted |
| [UTERM-028](UTERM-028-exec-driver-commands.md) | Exec drivers declare commands and receive their invocations | accepted |
| [UTERM-029](UTERM-029-presentation-extras.md) | PDF and image-folder decks, and Go to Slide, for the presenter | accepted |
| [UTERM-030](UTERM-030-text-viewer-slides.md) | A slide style and deck images for the text viewer | accepted |
| [UTERM-031](UTERM-031-controller-keys-in-text-panes.md) | Controller keys in panes that take typed text, such as the source terminal | retracted |
| [UTERM-032](UTERM-032-run-time-input-file.md) | A script takes its input file as an argument, and its folder is granted for slide images | accepted |
| [UTERM-033](UTERM-033-reclaim-restored-group.md) | A controller that runs again after a relaunch adopts its restored group, with the user's approval | accepted |
| [UTERM-034](UTERM-034-script-file-read-by-invoker.md) | Who reads a script file, so the app never opens a path the program chose | draft |
| [UTERM-035](UTERM-035-keyboard-after-an-applet-ends.md) | Where the keyboard goes when a pane's or window's applet ends without the user's doing | retracted |
| [UTERM-036](UTERM-036-program-opens-take-focus.md) | A program's opens and layouts take focus as the user's do | implemented |

## Dependency Graph

```text
UTERM-001
UTERM-002 ← UTERM-001
UTERM-003 ← UTERM-001
UTERM-004 ← UTERM-001, UTERM-003
UTERM-005 ← UTERM-001
UTERM-006 ← UTERM-001
UTERM-007 ← UTERM-001, UTERM-003, UTERM-004, UTERM-006, UTERM-013
UTERM-008 ← UTERM-001
UTERM-009 ← UTERM-001
UTERM-010 ← UTERM-001, UTERM-004
UTERM-011 ← UTERM-001
UTERM-012 ← UTERM-001
UTERM-013 ← UTERM-001, UTERM-002
UTERM-014 ← UTERM-002, UTERM-013
UTERM-015 ← UTERM-001, UTERM-002, UTERM-003, UTERM-004, UTERM-013
UTERM-016 ← UTERM-004, UTERM-008, UTERM-013, UTERM-015
UTERM-017 ← UTERM-001
UTERM-018 ← UTERM-003, UTERM-004, UTERM-005, UTERM-007, UTERM-013, UTERM-015
UTERM-019 ← UTERM-003, UTERM-004, UTERM-005
UTERM-020 ← UTERM-019
UTERM-021 ← UTERM-003, UTERM-004
UTERM-022 ← UTERM-003, UTERM-004, UTERM-021
UTERM-023 ← UTERM-003, UTERM-004
UTERM-024 ← UTERM-002, UTERM-003, UTERM-004, UTERM-013, UTERM-021
UTERM-025 ← UTERM-003, UTERM-004, UTERM-007, UTERM-015, UTERM-021, UTERM-024, UTERM-030, UTERM-032
UTERM-026 ← UTERM-001, UTERM-002, UTERM-004, UTERM-013, UTERM-021, UTERM-024, UTERM-025, UTERM-032
UTERM-028 ← UTERM-004, UTERM-013, UTERM-024
UTERM-029 ← UTERM-007, UTERM-024, UTERM-025, UTERM-026, UTERM-030, UTERM-032
UTERM-030 ← UTERM-004, UTERM-007, UTERM-015, UTERM-024, UTERM-032
UTERM-032 ← UTERM-003, UTERM-004, UTERM-015, UTERM-021
UTERM-033 ← UTERM-004, UTERM-021
UTERM-034 ← UTERM-003, UTERM-015, UTERM-021, UTERM-032
UTERM-036 ← UTERM-004, UTERM-015
```

## Not Yet Filed

- User-written custom applets. The write-up calls this pie-in-the-sky. File it after UTERM-004 settles the control
  model.
