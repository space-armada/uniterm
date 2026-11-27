# Proposals

| Proposal | Description | Status |
|----------|-------------|--------|
| [UTERM-001](UTERM-001-foundation.md) | Windows, regions, pane tree, status bar, and the libghostty terminal applet | implemented |
| [UTERM-002](UTERM-002-command-palette.md) | Floating or docked command palette with tab search | implemented |
| [UTERM-003](UTERM-003-janet-scripting.md) | Embedded Janet, host API, `uniterm run`, and the REPL applet | implemented |
| [UTERM-004](UTERM-004-control-and-trust.md) | Pane control, durable controller trust, scoped approvals, and layout requests | implemented |
| [UTERM-005](UTERM-005-browser-applet.md) | WebKit browser applet with tabs and a security indicator | implemented |
| [UTERM-006](UTERM-006-image-viewer-applet.md) | Image viewer applet with folder slideshow | accepted |
| [UTERM-007](UTERM-007-text-viewer-applet.md) | Viewer for Markdown, RTF, Word, and PDF | implemented |
| [UTERM-008](UTERM-008-map-viewer-applet.md) | MapKit applet with custom pins | implemented |
| [UTERM-009](UTERM-009-data-viewer-applet.md) | Table viewer for CSV, JSON, and spreadsheets | implemented |
| [UTERM-010](UTERM-010-canvas-applet.md) | Canvas applet that programs draw on | draft |
| [UTERM-011](UTERM-011-widget-bar.md) | Widget bar region with small widgets | deferred |
| [UTERM-012](UTERM-012-shell-blocks.md) | Collapsible command blocks in the terminal | deferred |
| [UTERM-013](UTERM-013-shortcut-ownership-and-reopen.md) | Window versus applet shortcuts, and Cmd-Shift-T reopen | implemented |
| [UTERM-014](UTERM-014-palette-and-reopen-review-fixes.md) | Cmd-K palette, title bar dock, and reopenable exits | implemented |
| [UTERM-015](UTERM-015-cross-applet-file-opening.md) | Finder, File > Open, and other ways a file reaches an applet, and the path-reading power | implemented |
| [UTERM-016](UTERM-016-map-pin-editing.md) | Add, edit, and remove map pins by hand, and save them to GeoJSON | implemented |
| [UTERM-017](UTERM-017-status-bar-placement.md) | Where notices go, their levels, window status slots, and the shared queue | implemented |
| [UTERM-018](UTERM-018-open-in-nearest-capable-pane.md) | Every open walks to the nearest pane that can handle it | accepted |
| [UTERM-019](UTERM-019-browser-automation.md) | Controller scripts run JavaScript, follow page events, and send input in their own browser tabs | accepted |
| [UTERM-020](UTERM-020-inspector-bridge.md) | Console, network, interception, and debugging for controller tabs through a hidden Web Inspector | accepted |
| [UTERM-021](UTERM-021-declared-script-permissions.md) | Script files declare their powers, with strict mode by default and a lint | implemented |
| [UTERM-022](UTERM-022-questions-applet.md) | Scripts ask the user forms in a tabbed Questions pane, with live validation | implemented |
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
| [UTERM-034](UTERM-034-script-file-read-by-invoker.md) | Who reads a script file, so the app never opens a path the program chose | accepted |
| [UTERM-035](UTERM-035-keyboard-after-an-applet-ends.md) | Where the keyboard goes when a pane's or window's applet ends without the user's doing | retracted |
| [UTERM-036](UTERM-036-program-opens-take-focus.md) | A program's opens and layouts take focus as the user's do | implemented |
| [UTERM-037](UTERM-037-controller-browser-commands-act-as-the-users.md) | A controller's browser commands act as the user's | implemented |
| [UTERM-038](UTERM-038-program-map-moves-and-seeds-act-as-the-users.md) | A program's map move and browser seed act as the user's | implemented |
| [UTERM-039](UTERM-039-controller-browser-tabs-are-not-capped.md) | A controller's browser tabs are not capped | accepted |
| [UTERM-040](UTERM-040-program-map-pins-edit-the-map.md) | A program's map pins edit the map as the user's do | accepted |
| [UTERM-041](UTERM-041-uniform-tab-marker-slot.md) | A uniform marker slot for every tab, with an authority marker first | accepted |
| [UTERM-042](UTERM-042-actions-for-tabs-and-their-markers.md) | One action menu for a tab and its markers, with every action in the palette | accepted |
| [UTERM-043](UTERM-043-pause-controllers.md) | Pause controllers for a while without ending their grants | accepted |
| [UTERM-044](UTERM-044-shard-the-ci-ui-tests.md) | Shard CI's UI tests across macOS runners | accepted |
| [UTERM-045](UTERM-045-settle-ui-test-input.md) | Settle input before UI tests send it | accepted |
| [UTERM-046](UTERM-046-deterministic-package-test-flakes.md) | Make the logged package-test flakes deterministic | accepted |
| [UTERM-047](UTERM-047-rate-limit-status-per-source.md) | Rate-limit status posts per source, with a fair bar and session-keyed sources | draft |
| [UTERM-048](UTERM-048-pane-inspector.md) | A floating Pane Inspector that shows a pane's and its tabs' state, hidden state included | accepted |
| [UTERM-049](UTERM-049-save-and-open-browser-tab-sets.md) | Save a browser pane's tabs as uniterm JSON, uri-list, or bookmark HTML, and open them back | accepted |
| [UTERM-050](UTERM-050-current-directory-never-blocks-the-main-thread.md) | An applet's current directory never checks the file system on the main thread | accepted |
| [UTERM-051](UTERM-051-launch-reads-the-layout-off-the-main-thread.md) | The launch reads and decodes the layout file off the main thread | accepted |
| [UTERM-052](UTERM-052-browser-description-never-encodes-tabs-on-the-main-thread.md) | The browser's description never encodes every tab on the main thread | accepted |
| [UTERM-053](UTERM-053-browser-tab-work-never-grows-with-the-tab-count-on-the-main-thread.md) | The browser's per-tab work never grows with the tab count on the main thread | accepted |
| [UTERM-054](UTERM-054-screenshot-a-pane-or-tab.md) | Copy or save a screenshot of the current pane or tab, for the user and for programs | accepted |
| [UTERM-055](UTERM-055-exec-drivers-capture-panes.md) | External exec drivers capture panes through new exec frames | accepted |
| [UTERM-056](UTERM-056-native-controllers-across-scriptwire-versions.md) | What happens to a native controller when ScriptWire's version changes | deferred |
| [UTERM-057](UTERM-057-package-read-by-invoker.md) | Who reads a controller package's files when `uniterm run` starts it | accepted |
| [UTERM-058](UTERM-058-palette-tab-work-on-the-main-thread.md) | The palette lists and filters tabs without main-thread work that grows with the tab count | accepted |
| [UTERM-059](UTERM-059-terminal-change-check-never-encodes-every-tab.md) | The terminal's change check never encodes every tab | accepted |
| [UTERM-060](UTERM-060-keep-the-evidence-of-where-ui-test-input-went.md) | A failed UI run keeps XCTest's per-event confirmations and which app was frontmost, and a debug build records the input it receives | accepted |
| [UTERM-061](UTERM-061-palette-commands-run-in-the-nearest-pane-of-their-type.md) | A palette command of another applet type runs in the nearest pane of its type | accepted |
| [UTERM-062](UTERM-062-viewer-tabs.md) | The data, text, image, and map viewers hold several files as tabs | accepted |
| [UTERM-063](UTERM-063-outside-wires-stay-at-version-0.md) | Every external version stays at 0 until uniterm's maintainers declare it stable | accepted |
| [UTERM-064](UTERM-064-programs-name-what-they-act-on.md) | Every program command names its target, and opens answer with the identity of what they made | draft |
| [UTERM-065](UTERM-065-exec-drivers-read-paths-in-a-scope.md) | An exec driver asks for a read scope, approved for its run, and names paths in it | accepted |
| [UTERM-066](UTERM-066-verified-identity-for-exec-drivers.md) | An exec driver can be a verified package, and keep remembered approvals for its powers | draft |
| [UTERM-067](UTERM-067-stores-keep-what-they-cannot-read.md) | Every store keeps entries it cannot read, starting with the controller trust stores | draft |

## Dependency Graph

```text
UTERM-001
UTERM-002 ← UTERM-001
UTERM-003 ← UTERM-001
UTERM-004 ← UTERM-001, UTERM-003
UTERM-005 ← UTERM-001
UTERM-006 ← UTERM-001, UTERM-065
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
UTERM-019 ← UTERM-003, UTERM-004, UTERM-005, UTERM-041, UTERM-042
UTERM-020 ← UTERM-019
UTERM-021 ← UTERM-003, UTERM-004
UTERM-022 ← UTERM-003, UTERM-004, UTERM-021
UTERM-023 ← UTERM-003, UTERM-004
UTERM-024 ← UTERM-002, UTERM-003, UTERM-004, UTERM-013, UTERM-021
UTERM-025 ← UTERM-003, UTERM-004, UTERM-007, UTERM-015, UTERM-021, UTERM-024, UTERM-030, UTERM-032, UTERM-036
UTERM-026 ← UTERM-001, UTERM-002, UTERM-004, UTERM-013, UTERM-021, UTERM-024, UTERM-025, UTERM-032, UTERM-036
UTERM-028 ← UTERM-004, UTERM-013, UTERM-024
UTERM-029 ← UTERM-007, UTERM-024, UTERM-025, UTERM-026, UTERM-030, UTERM-032
UTERM-030 ← UTERM-004, UTERM-007, UTERM-015, UTERM-024, UTERM-032
UTERM-032 ← UTERM-003, UTERM-004, UTERM-015, UTERM-021
UTERM-033 ← UTERM-004, UTERM-021
UTERM-034 ← UTERM-003, UTERM-015, UTERM-021, UTERM-032
UTERM-036 ← UTERM-004, UTERM-015
UTERM-037 ← UTERM-005
UTERM-038 ← UTERM-008, UTERM-037
UTERM-039 ← UTERM-005, UTERM-037
UTERM-040 ← UTERM-008, UTERM-015, UTERM-016
UTERM-041 ← UTERM-004, UTERM-005, UTERM-037
UTERM-042 ← UTERM-004, UTERM-041
UTERM-043 ← UTERM-004, UTERM-019
UTERM-047 ← UTERM-001, UTERM-003, UTERM-004, UTERM-017, UTERM-022
UTERM-048 ← UTERM-003, UTERM-004, UTERM-013, UTERM-041
UTERM-049 ← UTERM-004, UTERM-005, UTERM-015, UTERM-018, UTERM-021
UTERM-050 ← UTERM-001, UTERM-004
UTERM-051 ← UTERM-001, UTERM-004
UTERM-052 ← UTERM-005
UTERM-053 ← UTERM-005, UTERM-041, UTERM-052
UTERM-054 ← UTERM-004, UTERM-005, UTERM-019
UTERM-055 ← UTERM-019, UTERM-028, UTERM-054
UTERM-056 ← UTERM-004, UTERM-021
UTERM-057 ← UTERM-004, UTERM-015, UTERM-034
UTERM-058 ← UTERM-002, UTERM-053
UTERM-059 ← UTERM-052
UTERM-061
UTERM-062 ← UTERM-018, UTERM-063, UTERM-064
UTERM-064 ← UTERM-018, UTERM-063
UTERM-065 ← UTERM-004, UTERM-015, UTERM-063
UTERM-066 ← UTERM-004, UTERM-063
UTERM-067 ← UTERM-004
```

## Not Yet Filed

- User-written custom applets. The write-up calls this pie-in-the-sky. File it after UTERM-004 settles the control
  model.
