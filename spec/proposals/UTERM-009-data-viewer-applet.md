# UTERM-009: Data Viewer Applet

**Status:** implemented
**Created:** 2026-10-31
**Updated:** 2026-11-06

## Dependencies

- UTERM-001
- UTERM-013, and UTERM-002's command registry milestone: M3's search commands are registry entries the applet declares

## Impacts

- UTERM-003 — "Input sources": the source-taking entry point is where "send data to an applet" lands for this applet
- UTERM-004 — "Input sources": pipe input waits on caller identification and the exec wire format

## Summary

A table viewer applet for CSV, JSON, and spreadsheet data. It supports filtering, sorting, and searching.

## Motivation

Tabular output is hard to read in a terminal. A table pane lets the user sort and filter it without leaving uniterm.

## Design Decisions (Settled)

### Table first

The applet shows data as a table. It supports filtering, sorting, and searching.

### Charts are out of scope

Charts and graphs are not part of this proposal. The write-up flags them as complex. A later proposal may add them.

### Input sources

Original question: whether data can arrive from a script or a pipe, as well as from a file.

Decision: files open from inside the pane now. Pipe and script input is deferred to UTERM-003 and UTERM-004.

- The pane starts from the launcher like any applet, so the applet factory does not change. Inside it, the user opens
  a file with an open panel, from an Open... registry command with no key in the File menu, or by dropping a file onto
  the pane. A drop accepts file URLs only.
- A pane shows one file. Opening another file replaces it: the old load is cancelled, and the new file starts with no
  sort or filter. The open panel selects one file. A drop of several files is refused with a message asking for one
  file, and the pane keeps what it showed.
- A drawer of open documents beside the table, as Preview has, is an idea for later. This proposal does not commit to
  it. Building it needs its own proposal, since it changes what a pane and its description hold.
- All loading goes through one internal entry point that takes a source. A source is a file URL, or a nested JSON value
  that a cell holds, which loads from memory with no file behind it. A byte-stream source is added when its first
  caller lands. It spools to a file when a format needs random access, as `.xlsx` does. Amended 2026-11-05; see
  Decision Log.
- App-level opening belongs to UTERM-015, the cross-applet proposal this decision committed to. Its File > Open on
  Cmd-O routes files here by type, and this Open... is the pane-local open it keeps. The data viewer declares CSV,
  `public.json`, and `.xlsx` at the owner rank. A GeoJSON file goes to the map, whose type is more specific. The data
  viewer binds no File > Open key.
- Pipe and script input waits on UTERM-003's "send data to an applet" host function and on UTERM-004's caller
  identification and exec wire format.

**Revisit:** when UTERM-003 settles how a caller reaches the app and UTERM-004 settles caller identification, decide
the byte-stream source, what a restored pane shows for data that had no file, and how a pipe reaches a pane.

Rationale: a pipe into a pane beside the calling terminal is the complete answer to the Motivation. It needs caller
identity and a channel, which UTERM-003 and UTERM-004 have not settled. A launcher source that runs a command was
weighed. Modeled on terminal program mode, it splits the line into words with no shell, so it refuses
`kubectl get pods -o json | jq .items`. Running it through a shell would add a second command language beside program
mode, and a second path from program to pane beside UTERM-004's exec. Deciding app-level opening here would change the
factory every applet implements, from one consumer. Left undone: until those proposals land, command output needs a
redirect to a file first.

### Spreadsheet formats

Original question: macOS has no built-in reader for Excel files. Support `.xlsx` through a Swift library such as
CoreXLSX, skip spreadsheets at first, or also support legacy `.xls` through a separate library.

Decision: read `.xlsx` with an in-house OOXML reader on ZIPFoundation. Legacy `.xls` is not supported.

- ZIPFoundation (MIT) reads the ZIP container. It is the project's first third-party Swift package. It is pinned to an
  exact version, its `Package.resolved` is committed, and its notice joins `Licenses/` through the collect script.
- The project owns the OOXML layer, on Foundation's event-driven `XMLParser`, so rows stream instead of loading a whole
  sheet tree. It reads shared strings, inline and rich-text strings, cell values placed by cell reference, cached
  formula results, date number formats with `date1904`, and sheet paths through `workbook.xml.rels`. Multiple sheets
  get a sheet picker.
- Nothing is evaluated. A formula with no cached value shows as empty, marked as not computed.
- `.xlsm` opens with its macros ignored. `.xls`, `.xlsb`, and password-protected files each show a message that names
  the format, never "corrupt".

Rationale: streaming rows fits the large files decision. CoreXLSX decodes each sheet into a full in-memory tree through
XMLCoder, brings three packages, and last shipped in March 2023. A fully in-house reader would make the project own
untrusted ZIP parsing, including ZIP64 and data descriptors, with no gain in correctness. The format logic the project
must get right either way, such as dates, stays in-house. libxls, the usual `.xls` reader, is C with a history of
memory-safety CVEs, maintained outside the OS, and would parse untrusted files in-process with the App Sandbox off.
The chosen reader still reaches C through libxml2 and zlib, but those are OS libraries that macOS updates patch. See
Risks. The Summary names spreadsheets, not `.xls`.

### JSON shapes

Original question: how JSON maps to a table. An array of flat objects is easy. Nested objects and arrays need a rule:
flatten, show as expandable cells, or reject.

Decision: flatten nested objects into columns, and show arrays as cells that open a nested table.

- Nested objects become columns named by their path, such as `user.login`. Arrays, and nesting past the flattened
  paths, show as cells that open a nested table on demand.
- A column's identity is its path as a list of key segments, not a dotted string. A dot inside a key is escaped only
  when the name is shown. So `{"a.b": 1, "a": {"b": 2}}` gives two columns. The sort state in the
  description names columns by that identity, as "The applet contract" refines it for repeated names.
- Every top-level shape opens as a table: an array of objects (columns are the union of keys, in first-seen order), an
  array of scalars (one column), an array of arrays (positional columns), a single object (key and value columns), and
  JSON Lines.
- A missing key and an explicit `null` display differently.
- Numbers display their original text, so a large integer or a long decimal is never rounded.
- A nested object with more than 64 members is a map keyed by data, such as IDs as keys. It is one expandable cell in
  place of that many columns. Objects flatten to six key segments, and what lies below is an expandable cell.
- A table holds at most 1,000 columns. Keys past that fold into one last expandable cell, so no value is lost.
- Duplicate keys in one object keep every value. The nth repeat of a key path in a row fills the path's nth column, by
  the same occurrence that separates repeated CSV headers.
- A nested table opens in a popover over its cell, within the pane, and a cell in it can open one more.
- A scalar on its own and a syntax error show a message and no rows. An empty array shows a message.
- Sorting a mixed column follows one order. Numbers come first, then text, booleans, nested cells, null, and missing.
  Descending reverses all but null and missing, which stay last.

Amended 2026-11-04; see Decision Log.

Rationale: common API fields become columns the user can sort and filter, and array contents stay tables instead of
text. Rejecting nested JSON would fail on most API output. Naming columns by segment list keeps two different values
from sharing a column, and fixes the stored sort and filter state before the payload format ships.

### Large files

Original question: a size limit, or streaming rows for large files. Whether sorting and filtering run off the main
thread.

Decision: rows stream off the main thread into memory, under one memory budget.

- Parsing runs off the main thread. Rows appear as they arrive, a status bar segment shows progress, and close cancels
  the load.
- Rows live in a compact in-memory store. The loaded rows are a snapshot, so a later change to the file cannot corrupt
  the view.
- One memory budget covers every data viewer pane together. Each pane keeps a floor of 32 MiB even when the budget is
  spent, so the app holds at most the budget plus one floor for each pane beyond it. A memory-pressure warning stops
  loading early. When loading stops, the pane says it shows the first N rows of the file, or of the sheet for a
  workbook. Amended 2026-11-05; see Decision Log.
- Sorting, filtering, and search run off the main thread on an immutable snapshot. A newer request cancels an older
  one, and results swap in when done.
- Loading is not running work. Reopen and relaunch read the file again, so closing a loading pane does not ask.

Rationale: one storage model works for every format, and once the load is done, nothing reads the file from the main
thread. A shared budget bounds the app, not just one pane, so a huge file cannot get uniterm killed along with its
terminals. Indexing a CSV file by row offset in a memory-mapped file was weighed. Rewriting the file in place, as
`cmd > out.csv` does, raises SIGBUS on a page past the new end, which crashes the app. Page faults on a stalled mount
block the main thread. And the offset index and sort permutation still need a budget for a file with hundreds of
millions of rows. A disk-backed row store for every format would let every row be viewed, but it copies a file as large
as the source to disk, and no one has asked to view every row of a multi-gigabyte file. Left undone: rows past the
budget cannot be viewed, and sort, filter, and search cover only the loaded rows.

### The applet contract

Original context and question: Context from UTERM-001, which shipped the applet contract. ADR-05 and ADR-06 cover its lifecycle and its description
versioning. An ADR for the rest of the contract is a candidate in UTERM-001's Decision Log. This proposal may reshape
it, so it is not written yet. Every applet implements:

- A view the pane hosts, a title, and status bar segments.
- `start`, `focus`, and a palette update.
- `detach`, `reattach`, and `close`. uniterm sends these lifecycle events, and each applet owns its response, per
  ADR-05. On detach an applet pauses audio, video, and alerts at once. uniterm keeps no closed applet alive. An applet
  that keeps work going after close owns its bound and a visible indicator.
  Superseded in part by UTERM-017; see Decision Log.
- `isRunningSomething` and `runningLabels`. Closing a pane, a window, or the app asks first when an affected pane is
  running something, and the dialog names it.
- `describe()`, an inert description with a type and a per-type version. Undo and layout restore both rebuild the
  applet from it, in the same place. Undo is not a snapshot of running state. An applet that wants undo to bring back
  more saves it in its description. ADR-03 says restoring it never runs a program the user did not ask for. ADR-06
  says the applet owns its payload and its version. It upgrades its own older versions, and bumps the version on any
  change an older build cannot round-trip. A description this build cannot read is kept byte-for-byte.

For the data viewer: a description likely holds the source file and the sort and filter state. When the data came from
a command's output, restoring must not run that command again.

Decision: the data viewer needs no change to the applet contract or the factory, beyond what UTERM-013 already makes.
Its description holds a path, a bookmark fallback, a start directory, and the view state, and never any data from the
file.

- Per UTERM-013, the data viewer declares its own commands in UTERM-002's registry: Find (Cmd-F), Find Next (Cmd-G),
  Find Previous (Cmd-Shift-G), and Focus Filter with no key. The filter field and the open panel need no key. The data
  viewer has no tabs, so its description has no undo-only part. Cmd-Shift-T reopens a closed data viewer pane from its
  description.
- All four sit in Edit > Find, a submenu of the Edit menu that an applet fills through a menu home of its own. The
  submenu shows only while the focused applet has such commands. The fixed edit actions stay as they were. The commands
  are off until a table shows. They run against the pane, so they work while the filter or find field has focus.
- The find query belongs to the pane. It is apart from the filter. Search marks cells among the rows the filter shows,
  numbered as shown, and runs again when the filter, the sort, or the loaded rows change. The query is not in the
  description, and the viewer never reads or writes the system find pasteboard. Amended 2026-11-04; see Decision Log.

- The payload holds the file's absolute path, a macOS bookmark of the file, the selected `.xlsx` sheet, the sort as a
  column identity and a direction, and the filter text. It has its own version, per ADR-06.
- Restore opens the stored path when a regular file is there. It uses the bookmark only when the path is missing, and
  then says where it found the file. A file renamed away and replaced by a new one at the same path shows the new one.
- Every description, the empty one included, holds the directory the pane started in. The factory passes it. An empty
  pane reports it as `currentDirectory`. With a file open, the pane reports the file's folder. The open panel always
  starts in `currentDirectory`. The open panel's own remembered directory is never used, since it is AppKit state, not
  the pane's.
- A column's identity is its key-segment list plus its occurrence among columns with the same name. A headerless CSV
  column, or an `.xlsx` column with no header, is named by its position. So two `amount` headers stay two columns, and
  a restored sort lands on the right one.
- The bookmark is created at load, and remade when an open, a restore included, finds a different file than the
  bookmark names. Resolution runs in `start()`, off the main thread, without UI and without mounting volumes.
  `describe()` never touches the disk.

Rationale: the path is what the user named, so it wins while a file is there. The bookmark recovers a file that was
moved or renamed. Bookmark-first resolution follows the file ID, which would show a rotated-away backup instead of the
fresh file. The launcher's `directory` and the terminal's `startDirectory` already carry the start directory
explicitly, and the data viewer follows them. Storing the rows in the description would contradict the large files
decision, write file contents that may hold secrets into the layout file, and make ADR-06 keep them byte-for-byte in an
older build. A size and modification-time marker was weighed. A dropped sort or filter is the confusion it targets, and
M1 already drops those per column. Equal size and time also do not prove a file is unchanged.

## Design Decisions (Open)

None.

## Risks

- **A huge file freezes the pane** — likelihood: medium, impact: medium.
  Mitigation: the large files decision parses, sorts, and filters off the main thread, under a shared memory budget.
- **A hostile file corrupts or takes over the app** — likelihood: medium, impact: high. The readers parse files from
  Downloads or email in uniterm's own process, with the App Sandbox off by design. The CSV, JSON, and OOXML logic is
  Swift, where a bug traps and ends every terminal pane's shell with the app. Under `.xlsx`, the bytes also pass through
  C: Foundation's `XMLParser` wraps libxml2, and inflation runs in the Compression framework or zlib. A bug there can
  corrupt memory silently, or run code with the user's privileges. The evidence does not settle the likelihood, so it
  is rated the higher of low and medium. Mitigation: libxml2 and zlib are OS libraries that macOS updates patch. M2 and
  M4 cap nesting depth, inflated bytes, and the shared strings table, and turn off external XML entities. Each reader's
  milestone fuzzes the parsing stack as shipped under a memory-error detector. This is the same exposure for which
  libxls was rejected, made smaller by OS maintenance and the caps, not removed. Moving parsing into a sandboxed helper
  process would remove it, and would add a helper target and a sandbox profile. **Revisit:** when fuzzing finds a
  memory error or a crash the caps do not prevent, or an advisory in a libxml2 or zlib path that `XMLParser` or
  inflation reaches is unpatched on a macOS version uniterm supports, file a proposal to move parsing into a sandboxed helper process.
- **The first third-party Swift package** — likelihood: low, impact: medium. ZIPFoundation brings a supply-chain path, a
  SwiftPM fetch in the build, and license collection that the build does not do yet. Mitigation: M4 pins it exactly,
  commits `Package.resolved`, collects its license, and settles the offline-build check's scope.
- **UTERM-002 and UTERM-013 are accepted but not built** — likelihood: medium, impact: low. If the command registry's
  shape shifts while it is built, M3's commands change with it. Mitigation: M3 depends on UTERM-002's registry
  milestone and starts after it.
- **Pipe input's restore rule is still open** — likelihood: medium, impact: low. When UTERM-003 and UTERM-004 settle,
  data that had no file may need a new payload field. Accepted: ADR-06's payload versioning makes that a version bump,
  and an older build keeps the newer description byte-for-byte.
- **The description is stored data** — the payload format is read by every later build. The design defuses the one-way
  door: the payload carries its own version per ADR-06, and an unreadable description is kept, not dropped.

## Milestones

### M1: CSV table

**Status:** DONE

- A pane can run the data viewer and open a CSV file as a table, from an open panel or by dropping a file on the pane
- Every load goes through the one source-taking entry point
- A drop accepts file URLs only, and the data viewer binds no File > Open key
- The Open... command with no key opens the panel, and the viewer declares CSV and `public.json` at the owner rank, for
  UTERM-015's router
- Opening a file into a pane that shows one replaces it, cancels any load still running, and clears the sort and
  filter. A drop of several files is refused with a message asking for one file, and the pane keeps what it showed
- The loader opens regular files only, so a FIFO, a device, or a stalled mount never blocks the pane, and reads off the
  main thread
- A missing or unreadable file shows a message in the pane. Stored sort and filter state that names an absent column
  is dropped, not an error, and only once loading has finished or stopped at the budget
- A file larger than the memory budget opens its first rows and keeps the "first N rows" notice visible while sorted,
  filtered, or searched. Counts read "X of the first N rows"
- Under an active sort or filter, rows that arrive while loading never show out of order
- Closing a pane mid-load frees its memory promptly, and closing it never asks
- The budget counts every row the panes hold, across all data viewer panes, and a memory-pressure warning stops loading
- Reopen and relaunch bring back the file with its sort and filter, and an empty pane reopens empty in its start
  directory. Reopen works through whichever key reopens a pane when M1 lands, and through Cmd-Shift-T once UTERM-013 M2
  lands
- A file moved or renamed after the save is found through its bookmark, and the pane says where. A new file at the
  stored path wins over the bookmark, and the bookmark is then remade for it
- The open panel starts in the pane's `currentDirectory`, never in the panel's remembered one. When the file's folder
  is gone, `currentDirectory` is the start directory, or nil when that is gone too
- A restored file in a folder behind macOS privacy protection, such as Downloads, shows a permission message when access
  is denied, not "missing" or "corrupt"
- A layout save never touches the disk to describe a pane, and an unchanged pane describes itself the same way twice
- Two columns with the same header keep separate identities, and a restored sort lands on the right one
- The launcher offers the data viewer, and restore picks the applet by description type. An unknown type still
  becomes a placeholder pane
- While the bookmark is still resolving, `describe()` returns the restored payload unchanged. Once the bookmark finds a
  moved file, the stored path becomes the new one
- The payload carries the sheet field from its first version, so M4 needs no version bump
- A pane that opens while other panes hold the whole budget still loads a minimum of rows, or says why it shows none.
  Restored panes share the budget the same way at every launch
- A fuzzing run with malformed CSV input, non-UTF-8 encodings included, through the parsing stack as shipped and under a memory-error detector,
  finds no crash and no memory error
- One documented rule picks a CSV file's header row, delimiter, and text encoding, and gives the same answer for the
  same file
- Clicking a column header sorts by that column
- A filter field hides rows that do not match

**As built:**

- The CSV rule is documented in the doc comment of the CSV rule type, beside its code. Best guesses behind it are in
  the Decision Log entry of 2026-11-04. UTF-32 is not supported. Bytes that are not valid UTF-8 past the first 64 KiB
  of a UTF-8 file show as U+FFFD.
- Size caps protect the store from a hostile file: a cell keeps 1 MiB, a row 16 MiB and 65,536 cells. A cut row is
  counted, and the status bar says how many rows had cells cut. Corrected 2026-11-05; see Decision Log.
- Rows live in sealed pages of about 1 MiB, which reserve their cost from the shared budget as they seal. A page the
  budget refuses is dropped, so the "first N rows" count is page-granular. A memory warning or critical event ends the
  loads running at that moment, and a pane opened afterward loads normally. Numbers and reasons are in the Decision Log
  entry of 2026-11-04.
- Sealed pages are copied into exact-size arrays, so a page holds what the budget charged for. A closed or replaced
  pane releases its lease, and a loader that is slow to notice its cancellation is refused from then on. The page being
  filled is not reserved and stays under about 1 MiB for each loading pane.
- A sort reserves its key memory from the same budget and gives it back when done. A sort the budget refuses leaves the
  rows in file order, and the status bar says so. See the Decision Log entry of 2026-11-04. Corrected 2026-11-05; see
  Decision Log.
- A header click cycles ascending, descending, then no sort. A sort or filter over a growing table reruns off the main
  thread at most every 250 ms. The view keeps the last finished result until the run over the newer snapshot ends, so
  rows never show out of order.
- The extension picks the reader. CSV, TSV, and TAB load. JSON, JSON Lines, and GeoJSON files load as JSON. The
  spreadsheet extensions go to the workbook reader, which decides by content, and any other extension is named and
  refused. The router declares CSV, JSON, and `.xlsx`, so a TSV or `.xlsm` file opens through the pane's own Open or a
  drop. Amended 2026-11-04; see Decision Log.
- The bookmark is made at open, kept when it still names the file that opened, and made again otherwise. Resolution
  runs off the main thread, and `describe()` returns the restored payload until it ends.
- Fuzzing: a seeded mutation fuzzer runs the loader, the store, and the sort and filter on mutated files. `make fuzz`
  builds the whole package under the address sanitizer in its own scratch folder, which links against the prebuilt
  GhosttyKit, then runs only the fuzzer. 5000 iterations at the default seed found no crash and no memory error.
  `make test-package` runs it at 300 iterations without the sanitizer, and `make ci` does not run `make fuzz`. The
  sanitizer does not instrument libxml2 or zlib, so M4's fuzzing covers their heap use only as the interceptors see it.
- A drop of several files is refused on the applet's drop entry point, and the package tests prove it. XCUITest cannot
  start a drag from Finder, so no UI test drives it.
- The visual check is left to the user. The run's screenshot of the running app was denied by its permission check.
  The UI suite drives the launcher, the open panel, Cmd-O routing, and restore. Things to look at in the visual check:
  the table's layout, the status segments, and the File menu. The menu shows two items titled "Open..." when a data
  viewer has focus, the window's routed Open and the pane-local one, and the pane-local one sits in its own section.
- On 2026-11-26 the user ran the visual check in the running app, with synthetic files. The table, the status segments,
  sorting, and the filter worked. The review asked for these changes, each its own commit: "Keep selected data viewer
  cells readable on the light palette", "Size data viewer columns to their content", "Measure data viewer columns in
  tabular digits", "Right-align numeric columns in the data viewer", "Show a long data viewer cell's whole value in a
  popover", and "Name the open file and offer Open beside the data viewer's filter". The palette's identical "Open..."
  rows became UTERM-061, and tabs for several files became UTERM-062.

### M2: JSON

**Status:** DONE

- An array of JSON objects opens as a table, one column per flattened key path
- Nested values follow the settled JSON shapes rule
- An object used as a map keyed by data, such as thousands of IDs as keys, becomes an expandable cell instead of
  thousands of columns
- Deeply nested input shows an error instead of crashing, and a top-level scalar or an empty array opens with a message
- A key that holds an object in some rows and a scalar or an array in others still shows every value
- Duplicate keys in one object follow one documented rule, and JSON Lines is told apart from a single JSON value
- Sorting a column with mixed types, `null`, and missing values follows one defined order
- The JSON reader is Swift, not `JSONSerialization`, so the large files and number-text rules hold
- A fuzzing run with malformed JSON input, through the parsing stack as shipped and under a memory-error detector,
  finds no crash and no memory error
- A large top-level array of objects streams within the memory budget, without parsing the whole document first

**As built:**

- The JSON rules are documented beside their code. The shapes, nesting, map, column cap, duplicate-key, and JSON Lines
  rules are in the doc comment of the JSON rule type. The mixed-type sort order is in the doc comment of the query
  engine. The numbers behind them, and the reasons, are in the Decision Log entry of 2026-11-04 that amends "JSON
  shapes".
- The reader is a streaming scanner in Swift. It takes chunks of any size, keeps each number's original text, and
  copies one array element or object member at a time, up to 16 MiB. A second pass flattens that element. So memory
  follows the budget and one element, and a file bigger than the budget stops after the first chunks it reads.
- Caps: nesting 256 levels, a string 1 MiB, a key 4 KiB, a nested cell 1 MiB, and 65,536 cells in a row. A string is
  cut. A number past 64 KiB, and a nested value past its cap, show a note in place of the value, since a cut number reads
  as a different value. A cut value, or a row that dropped cells, is counted in the same notice as a cut CSV cell. A
  repeat of a key costs the same however many came before it, and a long element checks for a cancel as rows pass.
- The row store gained typed pages for JSON. A cell carries a kind, and a row holds only the cells it has, found by
  binary search on column. So a missing key and `null` differ, and a sort can tell the string `"12"` from the number 12.
  CSV pages are unchanged.
- A syntax error, or nesting past the cap, ends the load with a message that names the line. The rows read before it
  are not shown. See the Decision Log entry of 2026-11-04.
- A nested cell shows its compact JSON after a marker, in the table's accent color. A double click opens it in a
  popover that holds its own table, sort, and filter, under the shared budget. A package test proves the load and the
  release of its rows. A UI test drives the double click, and it has not run. The coordinator's `make test-app` runs it.
- Fuzzing: the JSON corpus joined the existing fuzz class, with mutated files, random read splits, and an open of every
  nested cell. 5000 iterations at the default seed found no crash and no memory error under the address sanitizer.
  The sanitizer does not instrument the system libraries, but this reader uses none.
- A GeoJSON file opens as key and value rows. A large `features` member shows the too-large note, so a FeatureCollection
  is not browsable here. That is a known limit of loading GeoJSON as JSON. The router still sends GeoJSON to the map.
- The column registry is not charged to the budget. Its bound is 1,001 columns. Each holds at most 6 key segments of
  4 KiB, and a title of the same size, so the worst case is about 50 MiB for a hostile file and kilobytes for a real
  one. Each open nested popover also takes one more 32 MiB floor beyond the limit, as "Large files" allows.
- The visual check is left to the user. Things to look at: the nested-cell marker and color, the popover's size and
  position over a cell, `null` in a muted color, and a wide table's `(more keys)` column.
- On 2026-11-26 the user ran the visual check. The nested cells, the popover, `null`, and missing keys looked right.
  Opening a 1,100-key file froze the main thread, fixed in "Keep the main thread free while a wide data file opens",
  which also shows the file opening. Scrolling to the far edge of a wide table was slow, answered by "Add jump-to-edge
  arrows to long data viewer tables".

### M3: Search

**Status:** DONE

- Searching highlights matching cells and steps between them
- Find, Find Next, Find Previous, and Focus Filter are registry commands the data viewer declares, with menu items, and
  none of their keys is a reserved window key
- The Find items sit in Edit > Find, work while focus is in the filter field, and are disabled when no file is loaded

**As built:**

- Edit > Find is shared contract. An applet command names the new `editFind` menu home, and the menu builds the submenu
  below Select All. The rule that this home takes find commands only is a convention. Its doc comment states it, and
  the code does not enforce it. The submenu and its separator hide unless the focused applet type owns an item in it. Availability,
  the hidden-under-another-applet rule, the disabled-under-a-sheet rule, and the key reservation are the registry's
  and are unchanged. A command on a reserved key in this home loses the key and warns like any other. See the Decision
  Log entry of 2026-11-04.
- Find opens a find bar under the filter field with a match count. Return steps forward, Shift-Return steps back, and
  Escape closes the bar and clears the query. Find Next with no query opens the bar. Focus Filter is in the same
  submenu, in its own section.
- The keys work from a focused text field because the window routes a Command key to the menu before any view sees it.
  Find reaches the pane, not the field. A package test types the key into a real field editor, and the UI tests drive
  the same path in the app.
- Search runs in the session on the snapshot and the rows shown, off the main thread. Each new query or new rows
  cancel the older run. It matches ignoring case, as the filter does, and keeps at most 1,000,000 matches. A cut list
  reads "1,000,000+" in the count.
- The current match keeps its cell, by row of the file and column, when a filter, a sort, or new rows change what is
  shown. When that cell no longer matches, the first match after it takes over. Adding or deleting letters of the same
  word keeps the place. Any other query, and a cleared bar, starts at the first match. The view scrolls to the current
  match only for a new query or a step, so a reload of rows never pulls back a view the user scrolled.
- The count reads "X of N matches". It adds "in the first N rows" when the load stopped at the budget, and "in X of N
  rows" when a filter hides rows. Both together read "in X of the first N rows".
- A match is a tinted cell, and the current one is tinted more. The UI tests check the count line, not the colors. The
  visual check is left to the user. Things to look at: the two tints on both palettes, the find bar under the filter,
  and the scroll to the current match in a wide table.
- On 2026-11-26 the user ran the visual check. Find worked, but the filter field and the find bar looked alike, so the
  filter read as a find that highlighted nothing. The user picked a mockup that sets them apart, built in "Set the data
  viewer's filter and find apart".
- No change to table parsing, so `make fuzz` did not run.

### M4: Spreadsheets

**Status:** DONE

- An `.xlsx` file opens as a table, and a workbook with several sheets offers a sheet picker
- The viewer declares `.xlsx` at the owner rank, for UTERM-015's router
- Dates show as dates, under both the 1900 and the 1904 date systems, including Excel's serial 60
- Shared, inline, and rich-text strings show their text, and sparse cells land in the column their reference names
- A formula with no cached value shows as not computed
- A fuzzing run with malformed `.xlsx` input, through the parsing stack as shipped and under a memory-error detector,
  finds no crash and no memory error
- A file whose inflated entries pass a size cap stops with a message. The cap counts bytes actually inflated, not the
  sizes the archive claims, and the shared strings table has its own cap
- Rows stream: peak memory on a large sheet stays bounded, and the reader never buffers a whole sheet entry first
- External XML entities are off, and entity expansion is bounded
- `.xls`, `.xlsb`, and password-protected files each show a message naming the format; `.xlsm` opens
- The selected sheet survives reopen and relaunch
- ZIPFoundation is pinned exactly, `Package.resolved` is committed, its license notice is collected, and the
  offline-build check either covers SwiftPM fetches or states that it covers Ghostty only

**As built:**

- ZIPFoundation 0.9.20 is pinned with `exact:` in the package manifest. It is the newest release, and its tag was
  published 2025-09-24. Both `Package.resolved` files are committed, and both name revision
  `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`, the commit that tag points to. Only the table target depends on it. The
  license script collects a notice for every package the resolved file pins. It checks the checkouts before it wipes
  anything, and refuses one that is not at the pinned revision. The notice is in `Licenses/swift-packages`, with a line in `Licenses/README.txt`.
- The offline check covers SwiftPM fetches, the complete one of the two options. `make swiftpm-offline-check` runs in
  `make ci`. It fills a kept cache at `.cache/swiftpm` from the committed pins, shows with a control that a dead proxy
  stops both `swift` and `xcodebuild` from fetching, then resolves into empty folders from the kept cache alone. It builds
  the table target with automatic resolution off, and fails if a resolve rewrites either `Package.resolved`. CI keeps
  only `.cache/ghostty`, so a CI run fetches the package once, in the check's first step. That is accepted. See the
  Decision Log entry of 2026-11-04.
- The reader inflates a part on a second thread and hands it to `XMLParser` through a bound stream pair. The parser runs
  on the loader's thread and takes rows as they arrive. No part is ever held whole. A package test cancels a load of a
  sheet that inflates to about 5 MB after its first rows, and shows that under 1 MiB was inflated. A reader that gathered
  the part first fails it. Another test shows that no chunk is larger than the 64 KiB pipe. Caps count the
  bytes the inflating thread produced, never a size in the archive. A test gives a stored entry a lying size, and another
  inflates a sheet past a cap that its directory says is far smaller. Numbers and the reasons for them are in the Decision
  Log entry of 2026-11-04.
- Entity declarations are refused outright, not only bounded. The inflating thread stops at `<!DOCTYPE` or `<!ENTITY`
  before the parser sees the bytes, and the parser's own declaration callbacks stop the rest. External entities are off.
  A billion-laughs payload and an external-entity payload both end with a message and expand nothing.
- Aborting an `XMLParser` parse does not stop it. The parser reads and discards the rest of the stream,
  and a write to a closed pipe does not fail, so the inflating thread would inflate the whole part for nothing. The
  handler tells the inflating thread to stop at the moment it aborts. ZIPFoundation has two traps that the loader guards. It finds the end record by stepping back through the whole file one
  byte at a time, so a file with no end record in its last 64 KiB is refused first. A stored entry that claims more bytes
  than the file holds makes it call the consumer forever with empty chunks, so a second empty chunk ends the read. The
  archive opens through the descriptor the loader already checked, so a path swapped for a pipe after the check cannot
  block the pane. The checksum of each part is verified after its last chunk, and a mismatch fails the load with a
  message that says the data is corrupt, since the format is right and the bytes are wrong.
- Cells land by reference, so sparse and out-of-order cells keep their columns, and a cell with no reference follows the
  one before it. A reference whose letters run past the last column is cut and counted, not placed. A formula with no cached result shows "not computed" in a muted color, and holds no text, so a filter
  or a search never finds it. A number in a date style shows as `yyyy-MM-dd`, with the time when the format has one.
  Serial 60 shows 1900-02-29, serial 0 shows 1900-01-00, and the 1904 flag shifts every date. The time of day rounds to
  the millisecond and then cuts to whole seconds, as Excel does, so 23:59:59.6 stays on its day. A number outside what the
  system can show keeps its stored text. A percent or a currency format shows the stored number, since the viewer
  applies no number format but dates. Booleans keep their own kind, and error values show their code.
- The first row that holds anything is the header when every cell in it is text. A column with no header is named by its
  position, and repeated headers keep separate identities. A row with no cells that hold anything is dropped, so a blank
  row inside a table is not kept. Hidden sheets are left out of the picker, unless every sheet is hidden. A sheet name used twice gets a number, as in
  `Sheet (2)`, so each can be picked, and that name is what the description stores.
- The picker is a pop-up beside the filter. It shows for two or more sheets, and stays up beside a message, so a sheet
  with no rows never traps the user on it. Choosing a sheet loads it with no sort or filter. The chosen sheet is in the
  description from that moment, so a reopen or a relaunch brings it back, and a stored sheet the workbook no longer has
  falls back to the first. The sheet field was in the payload from its first version, so there is no version bump.
- `.xls`, `.xlsb`, a password-protected workbook, and another old Office file each show a message that names what the
  file is and what to do. They are told apart by content. A compound file's directory is read, and a walk that does
  not reach the end of the chain reads as `.xls`. An `.xlsb` is a ZIP archive whose workbook part is binary. A file with a spreadsheet
  extension that is none of these says it is not a ZIP archive. An `.xlsm` opens, and its macro part is never read.
- Fuzzing: the workbook corpus joined the existing fuzz class. It mutates the XML of each part before zipping, and the
  archive's own bytes. Its seeds are plain, rich-text, wide, deeply nested, entity, huge shared-strings, zip-bomb, broken
  package, and compound-file workbooks. The limits shrink for most iterations, so small files reach every cap. 5000
  iterations at the default seed found no crash and no memory error under the address sanitizer. ASan does not
  instrument libxml2 or zlib. It sees their heap use only through its allocator and memory-function interceptors, so an
  overflow inside their own code can go unseen. A clean run is weaker evidence for this reader than for the Swift readers.
  The walk of cells in the fuzz invariants covers a bounded part of a wide sheet, so the run stays linear.
- Known limits. `XMLParser` builds an attribute dictionary for every element, so a sheet of millions of cells loads at
  roughly the speed of a few hundred thousand elements a second. The sheet cap of 4 GiB inflated bounds the time, and a
  cancel is seen at the next row. Shared strings are charged to the budget while the sheet loads, and are given back at
  the end. A budget refusal while they load ends the load as a budget stop, or a memory-pressure stop, and never as a
  hostile file. Only a real size cap says the workbook may not expand. A row counts in the "oversized cells cut" notice
  when it holds a cut cell, and a cell that shows a cut shared string is a cut cell, so the unit is rows, as in CSV and
  JSON. A stop that leaves columns and no rows shows the memory message in place of an empty table.
- The tests of both packages that read workbooks build archives with one writer, in the `TableTestSupport` test-support
  target. The UI-test target cannot import the package, so it keeps a copy of the writer and says so.
- The visual check is left to the user, and the UI tests have not run. The coordinator's `make test-app` runs them. The UI
  tests open a workbook through Cmd-O, switch sheets through the picker, and restore a stored sheet. Things to look at:
  the picker's place above the filter, "not computed" cells, and a workbook with a date column.
- On 2026-11-26 the user ran the visual check on a three-sheet workbook and a 1904-date workbook. The sheet picker,
  "not computed" cells, cached formula results, and every date, serial 60 and the 1904 shift included, looked right.

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-11-01: Added "The applet contract" with context from UTERM-001's implementation.
- 2026-11-02: Review start: 3 milestones, 2 settled decisions, 1 risk, no `**Live after:**` lines or row gates; one
  out-of-scope statement (charts); proposal at commit 8c5291d. The user asked for a design review of the open
  questions, in autonomous mode.
- 2026-11-02: JSON shapes: flatten nested objects into columns named by key-segment paths, and open arrays as nested
  tables. Every top-level shape opens. (autonomous)
- 2026-11-02: Spreadsheet formats: `.xlsx` through an in-house streaming OOXML reader on ZIPFoundation, the project's
  first third-party Swift package. No `.xls`. Added M4 for spreadsheets. (autonomous, addition: the first
  third-party package and the pinning and license-collection policy it brings)
- 2026-11-02: Input sources: in-pane file opening through one source-taking entry point; pipe and script input deferred
  to UTERM-003 and UTERM-004, and app-level file opening to a cross-applet proposal to be filed, both under the
  settled entry's revisit hook. The judge ruled after the critic's top choice moved to a launcher command source and
  back. (autonomous, judge, addition: the commitment to file a cross-applet file-opening proposal)
- 2026-11-02: Large files: rows stream off the main thread into memory under one budget shared by every data viewer
  pane, with a "first N rows" notice. Sort, filter, and search run off the main thread. (autonomous)
- 2026-11-02: The applet contract: no contract change. The description holds a path with a bookmark fallback, an
  explicit start directory in every state, the sheet, and the sort and filter by occurrence-qualified column identity.
  It never stores file data. The open panel's remembered directory is replaced by the explicit start directory.
  (autonomous)
- 2026-11-02: Coherence review. Amended "The applet contract": the open panel starts in `currentDirectory`, not always
  the start directory. Before, a pane with a file open sent its panel back to the start directory, while a split from
  it started in the file's folder. Added the data viewer's registry commands per UTERM-013, a dependency on UTERM-013
  and UTERM-002's registry milestone, and "reopen" wording in place of "undo". (autonomous)
- 2026-11-02: Risk review. Added risks for parsing untrusted files in-process, the first third-party package, the
  unbuilt registry, and the open pipe-restore rule, and noted the description's one-way door. Mitigated the crash risk
  with caps and fuzzing in M1, M2, and M4, rather than a sandboxed parser process. (autonomous)
- 2026-11-02: Re-check. Restated the untrusted-file risk: `.xlsx` parsing reaches C through libxml2 and zlib, so the
  worst case is memory corruption or code execution, not a trap. Mitigated by OS-patched libraries, the caps, and
  fuzzing under a memory-error detector. A sandboxed helper waits on the risk's revisit hook. (autonomous)
- 2026-11-02: Review gate: kept all. The user chose the open panel's explicit `currentDirectory` over AppKit's
  remembered folder, as CLAUDE.md asks for hidden state flow.
- 2026-11-02: ADR candidate (cuts across the system): untrusted files are parsed in-process only through Swift and
  OS-maintained C libraries, and a third-party C parser is rejected. Undecided on 2026-11-04. M4's fuzzing found no
  crash and no memory error, and the untrusted-file risk's revisit hook has not fired. The sanitizer does not instrument
  libxml2 or zlib, so the run is weaker evidence than for the Swift readers. The final review lists it.
- 2026-11-02: ADR candidate (cuts across the system): every third-party Swift package is pinned to an exact version,
  with `Package.resolved` committed and its license collected. Undecided on 2026-11-04. M4 settled that the offline-build
  check covers SwiftPM fetches. The final review lists it.
- 2026-11-02: Accepted by the user after the review.
- 2026-11-03: Amended "The applet contract": the bookmark is remade when an open finds a different file than the
  bookmark names. Before, it was created once at load and refreshed only when resolution reported it stale. So after
  a renderer rotated `render.png` away and wrote a new one, the path won on restore but the bookmark still named the
  rotated-away file. Once the new file was renamed, the next restore followed the bookmark to the stale file. Found in
  the UTERM-006 review, which settles the same rule. The marker on the `currentDirectory` bullet moved here, since a
  decision carries one marker; the 2026-11-02 entry above still records that change.
- 2026-11-03: Amended "Input sources": a pane shows one file, opening another replaces it, and a drop of several files
  is refused with a message asking for one. Before, the decision said nothing about either case. Noted a Preview-style
  document drawer as an idea that needs its own proposal. The user's decision.
- 2026-11-03: Scheduled as UTERM-009 M1-M4 in queue.md.
- 2026-11-03: Amended "Input sources" for UTERM-015. App-level opening waited on a cross-applet proposal this decision
  committed to filing. UTERM-015 is that proposal, now accepted. The viewer gains an Open... command with no key and
  declares CSV, JSON, and `.xlsx` as owner. Revisit-hook audit: act on the filing clause, which is done and removed.
  The byte-stream clause stays.

- 2026-11-04: Amended "Large files": each pane keeps a 32 MiB floor of the budget, so the app holds at most the budget
  plus one floor for each pane beyond it. Before, the text said one budget covered every pane and gave no floor, while
  the milestone asks that a pane opened last still loads a minimum of rows. Both cannot hold without a floor.
  (work-queue best guess)
- 2026-11-04: CSV rule picked in M1. Encoding: a byte-order mark wins, then valid UTF-8 in the first 64 KiB, then
  Windows-1252. Delimiter: `.tsv` and `.tab` mean tab, otherwise the first 64 KiB is tried with comma, semicolon, tab,
  and pipe, and the most consistent field count above one wins, with ties to comma. Header: the first row is the header
  unless a cell is a number, and an empty header cell is named by position. The rule rests on this proposal's "The
  applet contract" and M1 text, which say only that one documented rule exists. (work-queue best guess)
- 2026-11-04: Budget numbers picked in M1: the smaller of 1 GiB and a quarter of physical memory, a 32 MiB floor for
  each pane, and pages of about 1 MiB. "Large files" names no number. Only constants change if they are wrong.
  (work-queue best guess)
- 2026-11-04: Readers are picked by file extension, and a declared type the viewer cannot read yet shows a "not
  supported yet" message. Any other extension is refused with its name, so `.txt` does not open as CSV. TSV is not
  declared to the router, which keeps to the CSV and JSON declarations in "Input sources". (work-queue best guess)
- 2026-11-04: The fuzzer is an in-repo seeded mutator under the address sanitizer, not libFuzzer, and `make fuzz` stays
  out of `make ci`. The risk text asks for a fuzzing run per reader, not a CI gate. (work-queue best guess)
- 2026-11-04: A sort reserves its key memory from the shared budget, and a sort the budget refuses leaves the filtered
  rows in file order with a notice. The keys scale with the rows, which already fill the budget, so an unbounded sort
  could double the app's use. "Large files" says only that sort runs off the main thread on a snapshot.
  (work-queue best guess)
- 2026-11-04: A header click cycles ascending, descending, then no sort. Numbers sort before text when ascending, text
  sorts by its lowercased form, and empty cells come last in both directions. "Clicking a column header sorts by that
  column" fixes none of this. (work-queue best guess)
- 2026-11-04: Amended "JSON shapes". The decision named the flattening, the nested-table cells, and the top-level shapes,
  and gave no numbers or rules for width, repeats, or sorting. The text now holds them. A nested object with more than
  64 members is a map. Objects flatten to six key segments. A table holds 1,000 columns, and the keys past that fold
  into one last cell. Duplicate keys keep every value, in occurrence columns, as repeated CSV headers do. A nested
  table opens in a popover in the same pane. A scalar on its own, and a syntax error, show a message. The numbers are
  constants. The map threshold and the depth would change if real files flatten badly, and a user-facing setting is not
  warranted until someone needs one. (work-queue best guess)
- 2026-11-04: JSON Lines is told from a single value by the file name, then by the first 64 KiB. A name ending in
  `.jsonl` or `.ndjson` is JSON Lines. Any other name is JSON Lines when the sample holds a whole first value and a
  second one. A value longer than the sample is one value, and data after it is an error. The milestone asks only for
  "told apart". (work-queue best guess)
- 2026-11-04: The mixed-type sort order is numbers, text, booleans, nested cells, null, then missing. Descending reverses
  the first four, and null and missing stay last in both directions, as empty cells already did in M1. A JSON string
  sorts as text even when it looks like a number, and a number compares as a double. M1 left the full order to M2.
  (work-queue best guess)
- 2026-11-04: A syntax error or a nesting past the cap fails the load and shows no rows, even when rows were read first.
  The alternative keeps the rows with an error notice, and needs a new end state in the session, the phase, the notices,
  and the status segment. "Deeply nested input shows an error" allows either. (work-queue best guess)
- 2026-11-04: Amended M1's As built note on readers. A GeoJSON file is JSON, so it loads as JSON in place of showing
  "not supported yet". Before, M1 listed it with the formats that waited for a later reader. The router still sends
  GeoJSON to the map. (work-queue best guess)

- 2026-11-04: Edit > Find as an applet menu home (work-queue best guess). "The applet contract" named the find commands
  and no menu. M3 and UTERM-007 name Edit > Find. Applets could not place a command in Edit, so the menu gained an
  `editFind` home. It builds a Find submenu below the fixed edit actions, shown only while the focused applet has
  commands in it. UTERM-013 keeps the standard edit actions as fixed uniterm items. This adds nothing to them, and the
  home takes find commands only. UTERM-007's viewer uses the same home. Focus Filter sits in the same submenu, in its
  own section. All four are off until a table shows. Amended "The applet contract" with the placement. Before, it
  named the commands and not the menu, and it said nothing of the find query. The decision carries one marker, so the
  marker moved here from the bookmark bullet. The 2026-11-03 entry above still records that change.
- 2026-11-04: The find query is pane state, apart from the filter, and not in the description (work-queue best
  guess). Search covers the rows the filter shows, numbered as shown, and reruns when the filter, sort, or loaded rows
  change. Searching the whole file and showing hits in filtered-out rows was weighed. It needs a second row space and a
  way to show hidden hits. The query is left out of the payload so it needs no version bump, and a restored pane starts
  with the find bar closed. UTERM-007 already says its find query belongs to the pane and never touches the system find
  pasteboard, so this follows it.
- 2026-11-04: Search matches ignoring case, in every column, and keeps at most 1,000,000 matches (work-queue best
  guess). The matches live outside the budget, at 8 bytes each. A search with more is not a way to find a cell, and the
  count says so with a plus sign. "Large files" says only that search runs off the main thread on a snapshot.

- 2026-11-04: ZIPFoundation 0.9.20 is the pin (work-queue best guess). It is the newest release at least two weeks old,
  published 2025-09-24. The proposal says only "an exact version". The check is `exact:` in the package manifest and a
  matching revision in both `Package.resolved` files. A newer release needs a deliberate edit.
- 2026-11-04: The offline check covers SwiftPM fetches (work-queue best guess). M4's check allowed either that or a
  statement that it covers Ghostty only. A sibling script is added in place of growing the Ghostty one, since the two
  share nothing but the dead proxy and the control. It uses a kept cache at `.cache/swiftpm` that it fills first from
  the committed pins, and it covers both `swift` and `xcodebuild`. If the control cannot cut the network on a machine,
  the script fails and says so, and the fallback is to state that the check covers Ghostty only.
- 2026-11-04: Spreadsheet caps and rules picked in M4 (work-queue best guess). Inflated bytes: 32 MiB for each small
  part, 64 MiB for the shared strings table, which is also charged to the memory budget, and 4 GiB for the sheet. An
  archive holds at most 100,000 entries and XML nests 64 deep. A cell keeps 1 MiB, a row 16 MiB and 65,536 cells, and a
  sheet 16,384 columns. A DOCTYPE or an entity declaration is refused outright, which is stronger than bounding
  expansion, since no workbook holds one. The first row that holds anything is the header when all of it is text, rows
  with no content are dropped, hidden sheets are not listed, and only date formats change how a number shows. "Spreadsheet
  formats" and M4 name none of these. Only constants and the header rule change if they are wrong.
- 2026-11-04: Choosing a sheet clears the sort and the filter (work-queue best guess). The columns of another sheet are
  not the old sheet's, so a stored sort could land on a wrong column. The description holds one sort and one filter, not
  one for each sheet. Remembering a query for each sheet was weighed and needs a payload change.
- 2026-11-04: A formula with no cached value shows the text "not computed" and holds no bytes (work-queue best
  guess). "Spreadsheet formats" says it shows as empty, marked as not computed. The cell is empty in the store, so a
  filter and a search never match it, and it sorts with null. The view draws the marker.
- 2026-11-04: Amended M1's As built note on readers. The spreadsheet extensions now go to the workbook reader, and the
  router also declares `.xlsx`. Before, spreadsheet files showed a "not supported yet" message, and the router declared
  CSV and JSON only. (work-queue best guess)

- 2026-11-04: Two more spreadsheet rules (work-queue best guess). A sheet name used twice is numbered, as in `Sheet (2)`,
  and the description stores the numbered name. A time of day rounds to the millisecond and then cuts to whole seconds,
  as Excel shows it, so a date-only style never rolls into the next day from rounding to the second.

- 2026-11-05: Amended "Input sources": a source is a file URL, or a nested JSON value that a cell holds, which loads from
  memory with no file behind it. Before, the text said all loading goes through one entry point that takes a source, and
  that the only source today is a file URL. The nested-table work added the in-memory source to that same entry point
  and not to a second one, so the entry point stays single and its text was out of date. The marker on the one-file
  bullet moved here, since a decision carries one marker; the 2026-11-03 entries above still record that change.
- 2026-11-05: Amended "Large files": the stop notice says "of the sheet" for a workbook and "of the file" otherwise
  (work-queue best guess). Before, it said "of the file" for every format. The count text already read "X of the first
  N rows" in both cases, so it is unchanged. "Sheet" follows the sheet picker's own word. If the guess is wrong, only
  the notice string changes.
- 2026-11-05: A budget or memory-pressure refusal while a workbook's shared strings load ends the load as a budget stop
  or a memory-pressure stop (work-queue best guess). Before, it failed the load with the "limits how far a workbook may
  expand, so a hostile file cannot use all memory" message, which is false for a normal workbook that other panes
  crowd out. The shared strings table is the first thing a workbook charges to the budget, so a refusal there leaves no
  rows, and the pane says so in the words it uses for a CSV file. The hostile-file wording stays on the real caps.
  A stop that leaves columns and no rows now shows the same message as a stop with no columns, in place of an empty
  table under a "first 0 rows" notice.
- 2026-11-05: The "oversized cells cut" notice counts rows that hold a cut cell, for a workbook too (work-queue best
  guess). Before, a workbook counted the shared strings that were cut, so a long string used in many rows counted once
  and a long string used in none counted at all. A cell that shows a cut shared string is now a cut cell, so the unit
  matches CSV and JSON.
- 2026-11-05: Correction of fact: the 2026-11-05 "Large files" entry above moved that decision's "Amended" marker from
  the 2026-11-04 "Large files" entry, and did not say so. A decision carries one marker, so the 2026-11-04 entry still
  records its own change. The prior meaning is that the 2026-11-05 "Input sources" entry was the only one of the two
  that named a moved marker. No As built text changes.
- 2026-11-05: ADR candidate (cuts across the system, hard to reverse): a file-backed viewer's description holds a path
  and a bookmark, never file contents. The path wins while a regular file is there, and the bookmark is remade when it
  names a different file than the one opened. Undecided. UTERM-006, UTERM-007, and UTERM-008 follow the same rule. The
  description is stored data, so a change needs a version bump and a migration. Settled in "The applet contract". The
  final review lists it.
- 2026-11-05: Correction of fact: M1's As built said the pane says how many rows had cells cut, and that a refused sort
  leaves a note in the pane. At the user's review, load notices moved to the status bar. Each posts once per load as a
  warning and stays in the history. Segments carry "first N rows", "N rows cut", and "Unsorted" while the pane has
  focus. The pane keeps only load failures and the wait while loading. The prior meaning was a notice line under the
  filter. The "Large files" check still says the "first N rows" notice stays visible. A segment meets it only while
  the pane has focus, so that check now reads as the status bar's.
- 2026-11-06: Superseded in part by UTERM-017. "The applet contract" said an applet pauses alerts on detach, and the
  viewer posted its load notices from detached panes as if they were not alerts. UTERM-017 makes load notices alerts.
  An applet withholds their presentation while detached, records them in the window history when they occur through
  history-only delivery, and presents the bounded rest on reattach. UTERM-017 also records one history entry when a
  load failure or a memory stop leaves the pane empty. M1 of UTERM-017 shipped that entry and the history-only
  delivery, and M3 changes the detached behavior.

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, APPLET-4
