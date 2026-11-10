# Proposals

| Proposal | Description | Status |
|----------|-------------|--------|
| [UTERM-001](UTERM-001-foundation.md) | Windows, regions, pane tree, status bar, and the libghostty terminal applet | implemented |
| [UTERM-002](UTERM-002-command-palette.md) | Floating or docked command palette with tab search | implemented |
| [UTERM-003](UTERM-003-janet-scripting.md) | Embedded Janet, host API, `uniterm run`, and the REPL applet | implemented |
| [UTERM-004](UTERM-004-control-and-trust.md) | Pane control, durable controller trust, scoped approvals, and layout requests | accepted |
| [UTERM-005](UTERM-005-browser-applet.md) | WebKit browser applet with tabs and a security indicator | accepted |
| [UTERM-006](UTERM-006-image-viewer-applet.md) | Image viewer applet with folder slideshow | accepted |
| [UTERM-007](UTERM-007-text-viewer-applet.md) | Viewer for Markdown, RTF, Word, and PDF | accepted |
| [UTERM-008](UTERM-008-map-viewer-applet.md) | MapKit applet with custom pins | accepted |
| [UTERM-009](UTERM-009-data-viewer-applet.md) | Table viewer for CSV, JSON, and spreadsheets | implemented |
| [UTERM-010](UTERM-010-canvas-applet.md) | Canvas applet that programs draw on | draft |
| [UTERM-011](UTERM-011-widget-bar.md) | Widget bar region with small widgets | deferred |
| [UTERM-012](UTERM-012-shell-blocks.md) | Collapsible command blocks in the terminal | deferred |
| [UTERM-013](UTERM-013-shortcut-ownership-and-reopen.md) | Window versus applet shortcuts, and Cmd-Shift-T reopen | implemented |
| [UTERM-014](UTERM-014-palette-and-reopen-review-fixes.md) | Cmd-K palette, title bar dock, and reopenable exits | implemented |
| [UTERM-015](UTERM-015-cross-applet-file-opening.md) | Finder, File > Open, and other ways a file reaches an applet, and the path-reading power | accepted |
| [UTERM-016](UTERM-016-map-pin-editing.md) | Add, edit, and remove map pins by hand, and save them to GeoJSON | accepted |
| [UTERM-017](UTERM-017-status-bar-placement.md) | Where notices go, their levels, window status slots, and the shared queue | implemented |
| [UTERM-018](UTERM-018-open-in-nearest-capable-pane.md) | Every open walks to the nearest pane that can handle it | accepted |

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
```

## Not Yet Filed

- User-written custom applets. The write-up calls this pie-in-the-sky. File it after UTERM-004 settles the control
  model.
