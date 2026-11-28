# UTERM-049: Save and Open Browser Tab Sets

**Status:** accepted
**Created:** 2026-11-22
**Updated:** 2026-11-27

## Dependencies

- UTERM-004, for the control framework a program's call is granted under
- UTERM-005, for the browser's tabs, their stored URL and title filters, and the scheme policy
- UTERM-015, for the file router, type declarations, and the `Info.plist` drift test
- UTERM-018, for where a routed file opens when no pane can take it in place
- UTERM-021, for the powers a script file declares
- UTERM-018 M5, for the script file open that a program's open of a tab file uses

## Impacts

- UTERM-005 — "Schemes" and the layout payload's URL and title filters. A tab file is a second writer and reader of the
  same filtered values.
- UTERM-015 — "How a file type maps to an applet". The browser declares its first opened types, and the app exports
  its first types.
- UTERM-015 — "Who may run `uniterm open`" and "Which file types uniterm registers with Finder". A program's open of a
  tab file can load a page, per "A program-chosen open of a tab file". uniterm's own exported type may need a rank
  other than Alternate.
- UTERM-018 — "Applets whose open makes a new pane". The browser joins the terminal as an applet whose panes never take
  a file in place.
- UTERM-005 — "Control". A script's open of a tab file needs browser navigation, as a seeded layout URL does.
  `save-tabs` supersedes in part its rule that every browser command needs a browser permission and acts only on the
  controller's own tabs.
- UTERM-015 — the routed open. The router gains an optional prepare step that runs before an applet's factory.
- UTERM-018 — "Scripts and controllers" and M5. A script's file open may make a pane under pane control, for an applet
  whose open always makes one. Amended 2026-11-22.

## Summary

A browser pane saves its tabs to a file. The save panel's format control offers a uniterm tab-set JSON format, the
default, plus `text/uri-list` and Netscape bookmark HTML. A tab-set JSON or `text/uri-list` file opens back into a new
browser pane, and only its selected tab loads. Scripts and controllers get the same save and open under a granted power.

## Motivation

A set of open pages cannot leave uniterm today. The layout file records each tab's committed URL and title and the
selected tab, but it is one autosaved file under Application Support, so its tabs cannot be kept, shared, or reopened
on their own. No browser command copies or exports a URL.

No standard format covers a tab set fully. `text/uri-list`, from RFC 2483, is registered with IANA and suggests the
`.uris` extension. It holds one URL per line with `#` comments, and has no titles or selected tab. The Netscape
Bookmark File Format is HTML that every browser imports. It carries titles and folders, but it is a bookmark format
with a plain `.html` extension. Firefox's session files and OneTab's export are each tied to one product. A uniterm
format keeps titles and the selected tab through a round trip, and the two standard formats let the tabs reach other
tools.

## Design Decisions (Settled)

### Save Tabs As is a browser command

Decision: the browser adds a Save Tabs As… command. Its home is the File menu, beside New Tab and Open Location, and it
appears in the palette. It acts on the target pane's browser, as every browser command does. It saves every tab of
that pane.

Rationale: the browser already owns its File items through `AppletCommand` with `home: .file`. The map viewer's Save As
is the precedent for an applet's own save. ADR-04 lets an applet bind keys only for its own actions. This one has
no default key; see "A default shortcut for Save Tabs As".

### The save panel picks the format

Decision: the save panel shows its own format control, through `NSSavePanel.showsContentTypes` with
`allowedContentTypes` listing the tab-set type, `text/uri-list`, and Netscape bookmark HTML, in that order. The tab-set
type is the default. The written format is the panel's `currentContentType` when the user clicks Save.

Rationale: the control and its extension handling are AppKit's own from macOS 15, and uniterm targets macOS 26. A
custom accessory view would rebuild what the panel already does.

### The tab-set format carries an extension and an in-file tag

Decision: the tab-set format has a uniterm-specific extension and a `UTType` under `dev.uniterm` that conforms to
`public.json`. The file opens with a tag and a version. "The extension and the type identifiers" settles their values.

- The extension decides which applet opens the file. The tag validates a file the browser receives: a file whose tag
  is not a tab set is refused with a message. A tab set renamed to `.json` opens in the data viewer as JSON, and
  renaming it back opens it as tabs. See "How the tag wins on open". Amended 2026-11-22; see Decision Log.
- A build reads every version up to its own. A newer version than the build knows is an error that names the version.
- The format holds tab sets only. A shared envelope for other uniterm data waits for a second payload, and the tag
  leaves room for one.

Rationale: the extension and its type are what macOS works with: Finder, the save panel, and UTERM-015's router. The
tag keeps a file self-describing, so the browser never reads a stray JSON file as tabs. Conforming to `public.json` keeps
editors and `jq` working. The version rule follows ADR-06's pattern for the layout file and ADR-13's spirit for
outside formats, though neither governs this file.

### Saved values reuse the layout's filters

Decision: each tab saves the URL and title its layout record holds, which is its last storable page. A tab that has
not loaded since restore saves its stored URL and title. Every URL passes `BrowserDescription.storableURL` again at
save time, and every title the same 512-character bound the layout payload uses, whatever its source. The file records
which tab is selected. The save reads the browser's tabs through the applet, never its web views directly. Amended
2026-11-22; see Decision Log.

- Opening a file applies the same bounds when it fills each tab's record. A URL over 32 KiB is not stored, and a title
  is cut to 512 characters.

Rationale: one filter keeps a saved file and a saved layout in agreement on which URLs are storable. Only http, https,
and `about:blank` pass, so a `blob:`, `data:`, or `javascript:` URL never reaches a file that other tools read, even
when an opened file put one in a tab. ADR-05 has the applet own its own state.

### The write is atomic and bounded

Decision: the file is written atomically, through a temporary file beside the target and a replace, as the map
viewer's Save As does. A failed write raises an error alert that names the file and keeps the user's earlier file. The
write runs off the main thread, as the map viewer's does, since a pane's tab count has no cap and each URL may be up to
32 KiB. Amended 2026-11-22; see Decision Log.

### The browser opens tab-set and `text/uri-list` files

Decision: the browser declares the tab-set type and `text/uri-list` at the owner rank. Both are exported or imported
in `Info.plist`, as UTERM-015 requires. Netscape bookmark HTML is export-only.

- The browser's "opens no file" rule narrows. It still opens no local page, since `file:` never loads, and the text
  viewer keeps local documents.
- The tab-set type conforms to `public.json`, so it is more specific than the data viewer's `public.json` claim and
  wins by UTERM-015's specificity rule.
- The router matches on the file's system type, from its extension. A tab-set file renamed to `.json` resolves to
  `public.json`, so the browser is not a claimant for it. See "How the tag wins on open".

Rationale: the user chose this pair. A bookmark file uses `.html`, so claiming it would take every HTML file away from
its other handlers or need sniffing.

### An opened file makes a new pane and loads lazily

Decision: an opened tab file makes a new browser pane beside the origin, by UTERM-018's rule for a file that no pane
takes in place. The browser does not replace a source, so its existing panes never take a file. The new pane holds
every tab the file lists, in order. Only the selected tab loads. Every other tab loads when first selected, as a
restored layout's tabs do.

- Each URL passes the scheme policy as a restored URL does. A refused URL keeps its tab, shows `about:blank` and an
  explanation, and keeps the URL, as a restored tab does.
- A `text/uri-list` file has no titles or selection. Its tabs show their hosts until they load, as an untitled
  restored tab does, and the first tab is selected.
- A file that lists more tabs than a threshold asks once, in a window sheet, before any pane or tab is made. The
  sheet names the file and the tab count, and lists the first URLs with "and N more", as the app's other sheets list
  items. Cancel makes nothing. A file at or under the threshold opens without asking. The same rule holds for every
  source: File > Open, a drop, Finder, `uniterm open`, and other apps. "Bounds on opening a file" settles the
  threshold's value.

Rationale: the user chose a new pane with lazy loading. A file with hundreds of URLs then fetches one page, so the
network work is bounded by the user's own selections, under ADR-03 and ADR-14 P15. Opening many tabs is often a
mistake, whoever asks for it, so a large set asks first, as a page's pop-ups past the browser's limit do. UTERM-018
already derives "never in place" from the applet contract, so no declaration field is added. Amended 2026-11-22; see
Decision Log.

### URLs are written as they are

Decision: export writes each storable URL unchanged. No query string or fragment is stripped, and the panel shows no
token warning.

Rationale: the user chose the file and its place. UTERM-005 accepted the same exposure for the layout file. Stripping
queries breaks pages whose query is the page, such as a search, and guessing which parameters are tokens is
unreliable.

### Scripts and controllers can save and open tab files

Decision: a script or controller can save a browser pane's tabs to a tab file and open a tab file into browser tabs.
Both behave as the user's commands do, per ADR-15. Each needs an authenticated requester and an explicit, revocable
grant under ADR-14 P7. "A program saves tabs through the user's save panel" and "How a program opens a tab file" name
the powers. Amended 2026-11-22; see Decision Log.

Rationale: the user added this to the proposal's scope.

### The extension and the type identifiers

Original question: what are the tab-set format's extension and its `UTType` identifier? `text/uri-list` needs an
identifier too, since the system has no type for it.

Decision: the tab-set format's extension is `.uniterm-tabs`. Its exported type is `dev.uniterm.tabs`, conforming to
`public.json`. The in-file tag is that identifier, so a file opens with `{"type": "dev.uniterm.tabs", "version": 1,
...}`. uniterm imports `text/uri-list` as `dev.uniterm.uri-list`, with the `.uris` and `.uri` extensions and the
`text/uri-list` MIME type.

Rationale: `.uniterm-tabs` names its owner plainly, and nothing traced breaks on the hyphen. One string serves as the
type and the tag, so the format has one published name instead of two. No one declares `text/uri-list` under a shared
identifier. The IETF publishes none, so a name such as `org.ietf.uri-list` would coin one in another organization's
namespace. Markdown's `net.daringfireball.markdown` is different, since other apps already declare it. Under uniterm's
own namespace, a collision can only be uniterm's own doing.

The extension and `dev.uniterm.tabs` are one-way doors. The `text/uri-list` identifier is not. A saved Open With choice
for a type no applet declares is ignored, and the router falls back to the types the system registers for `.uris`. See
Risks.

### The tab-set format's fields

Original question: what does the JSON hold beyond each tab's URL and title and the selected tab?

Decision: version 1 holds each tab's URL and title and the selected tab, and nothing else. Both the URL and the title
are optional, per "Tabs with nothing storable". Readers ignore keys they do
not know. The version bumps only for a change that an older reader would misread by ignoring the new key. A per-tab
field that picks which website data a tab loads with is an example.

Rationale: an older build then opens any file whose known fields keep their meaning. Bumping for every field would make
an older build refuse a file it could read whole. ADR-06 bumps for any dropped field because the layout is written
back, and a tab file is not. A set name and a save time would duplicate the file's own name and modification time, and
no reader shows them. Per-tab extras have no reader, and a favicon URL would be one more file-chosen URL to filter.

An older build that opens a newer file and saves it back to the same path drops the keys it does not know. That needs
the user to confirm Replace, so it is accepted.

### A program-chosen open of a tab file

Original question: a session approval for `uniterm open` covers every program in that session. Its text says "asks to
open this path in a new pane", and names no page load. A program in an approved session can write a `.uris` file and
open it. The new pane then loads its selected tab with uniterm's website data, signed in as the user. Elsewhere,
uniterm gates a program's browser page loads behind browser navigation: a seeded browser page in a layout request
needs that power, and UTERM-018 limits a program's URL opens to browser panes the program created. Any local process
can already make Safari load a URL through macOS `open`. What is new is uniterm's own website data.

Decision: a program's open of a tab file behaves exactly as the user's does, under the approvals that already gate
opens. It makes the same pane, loads the same selected tab, and asks the same question past the tab threshold. No
approval wording is specific to tab files. A script's own open, through UTERM-018's script file open, also needs
browser navigation whenever it would make a browser pane, whatever the file holds. See "How a program opens a tab file". Amended
2026-11-22; see Decision Log.

Rationale: a program running as the user can already read uniterm's website data directly. uniterm is not sandboxed,
and its cookie file sits in `~/Library/WebKit/dev.uniterm.app/WebsiteDataStore/<store>/Cookies/` with mode 644. On
2026-11-22, a launchd job with no Full Disk Access read it, while the same job was refused Safari's history. A signed-in
page load through a tab file therefore gives a program nothing it could not take itself. ADR-15 puts the authority
decision in the approval that lets the program open files at all, and the open then behaves as the user's.

That reasoning holds for a process running unsandboxed as the user, which is what `uniterm open` and Launch Services
serve. It does not hold for a Janet script, which UTERM-003 runs without network access unless its run grants it.

### Tabs with nothing storable

Original question: a tab whose record holds no storable URL has nothing to save. What does the file hold for it, and
what happens to the selection when the selected tab is such a tab?

Decision: the tab-set format writes such a tab as an entry with no `url`. The entry keeps the tab's bounded title when
it has one. The `url` key is optional from version 1. Opening the file makes a blank tab for that entry, as the layout
restores a tab that loaded nothing. Tab count, order, and the selection are kept. `text/uri-list` and bookmark HTML
cannot carry an empty entry, so they leave the tab out. Their selection is not recorded. A save in either of those
formats from a pane with no storable tab is refused with a message, since the file would be one uniterm refuses.

Rationale: the layout already holds such a tab as a record with a nil URL, so this writes what the layout holds and
needs no rule to move the selection. Skipping would add that rule, and a pane with nothing storable would write an
empty tab set that the open refuses. Making `url` optional now keeps version 1 readers able to read every later file
with empty entries, with no version bump.

### Bounds on opening a file

Original question: a tab file can list any number of URLs. Lazy loading bounds the fetches. What bounds the file's
size and the pane's tab count?

Decision: the tab threshold is 15. A file that lists more than 15 tabs asks before anything is made. Every tab file is
bounded at 32 MiB, the map's and the Markdown viewer's limit. The open stats the file, reads at most the limit plus one
byte, and parses, all off the main thread. A file over the limit is refused with a message that names it. Only then
does the threshold sheet show, and only after it does the pane exist. Save Tabs As applies the same limit to the
encoded file in every format, and refuses with a message naming it, so uniterm never writes a tab file it refuses to
open. No tab ceiling applies to an open the user confirms.

The routing path gains a step for this, as an applet contract every applet may use. An applet's type declaration may
name a prepare step. The router runs it off the main thread, before the factory. It reads and validates the file and
returns the prepared source and, when needed, a question to ask. The router shows the question, then hands the
prepared source to the factory, which never reads the file again. The count the sheet shows is then the count that
opens. Applets with no prepare step route as they do today. With no window, the question shows app-modal, as the batch
sheet does. Amended 2026-11-22; see Decision Log.

Leaves undone: a confirmed open of a huge count still stalls the main thread. The tab bar builds one view per tab, and
the layout saver encodes every tab on the main thread, at each change and at each launch's restore. Those are the
filed bugs `20261121-tab-bar-overflow-hides-tabs` and `20261122-layout-save-runs-on-main-thread`, and New Tab and
controllers reach the same state today.

Rationale: 15 is the number Firefox's `browser.tabs.maxOpenBeforeWarn` and Chrome's open-all-bookmarks prompt use for
the same operation. These are from their known defaults, not checked here. The app's own batch threshold of 10 bounds
a different operation, files opening into panes. A byte limit bounds what the file costs to read and parse. A tab
ceiling on file opens alone would be a special case, since other paths reach the same count. Dropping tabs past a
ceiling would lose them on the next save.

### A program saves tabs through the user's save panel

Original question: how does a script or controller save a browser pane's tabs? This is the save half of "The program
call".

Decision: the browser gains a `save-tabs` command. It shows Save Tabs As for the target pane, the panel the user's
command shows, with the same formats. The user picks the file and confirms any Replace. The command needs pane control
over the target pane, which must be among the program's targets under ADR-14 P1 to P3. The user's pick in the panel
authorizes the write, as it does for the user's own save, so no write power is needed. One panel is up at a time per
window, and a second request while one is up is refused, as the pane's other questions are. No new permission kind is
added. Amended 2026-11-23; see Decision Log.

Showing the panel is an effect, and the write that follows is another. So the reply follows ADR-11's handle shape, as
UTERM-022's `open-form` and `wait-form` do:

- `save-tabs` replies at once with a handle, once the panel shows. A refusal comes in this reply, and no panel shows.
- `wait-save` takes the handle and only reads, so it may hold a pending reply. It returns once the save settles. The
  outcome is `saved` with the path written, `cancelled`, or `failed` with the write's error. Reading does not consume
  the outcome. `wait-save` needs the same pane control as `save-tabs`.
- `discard-save` frees a handle. Discarding the handle of a panel that is still up dismisses the panel, and nothing is
  written.
- `wait-save` is the save's completion mechanism. ADR-11's completion event serves callers that read an event stream,
  and UTERM-004 gives remote callers no applet events, so a save's caller waits on its handle instead.
- A revocation, a run end, or a pane close while the panel is up dismisses it, writes nothing, fails a pending
  `wait-save` as ended, and frees the handle. One that lands during the write lets the write finish. A write failure
  then reaches the user's alert, as the user's own save does. The pending wait fails as ended, which never claims the
  save was undone.
- Save handles have the same caps and lifetimes as other ADR-11 handles. A connection holds at most 32, and a new one
  drops its oldest settled one.

This supersedes in part UTERM-005's "Control", which says every browser command needs a browser permission and acts
only on tabs the controller opened. `save-tabs` needs pane control alone and saves every tab in the pane, because the
user's pick in the panel, not the program, decides that anything is written.

Leaves undone: a program cannot save tabs unattended, such as on a schedule. A program with its own file access that
learns the path can read the saved URLs of a pane it did not open. That happens only after the user saves in the panel,
and is accepted.

Skew: the browser's command schema is at 0.0 and does not bump, per UTERM-063. `save-tabs` lands in place. A newer
program on an older uniterm is refused by name for a command that build does not know. An older program never meets a
changed meaning, since a changed meaning takes a new name. No permission kind crosses the descriptor or the policy
file, so neither changes. Amended 2026-11-27; see Decision Log.

Rationale: this is the user's own operation, under ADR-15. A path argument would need the first path-write power, and
a folder-scoped write could replace any file in that folder without the Replace the user's save shows. A tab-list read
power would make every program reimplement the format and add a power to read tabs it did not open. A reply held until
the write would fail after the file was written when the run is revoked mid-write, and the program would save again.
A reply settled when the user confirms would hide a failed write from the program. The handle tells the program every
outcome, and an interruption never misreports one.

### How the tag wins on open

Original question: the settled format decision says the tag decides what a file is. The router picks an applet from
the file's system type, which comes from its extension, and reads no content. How does the tag win on open?

- **The browser's reader checks the tag.** A file routed to the browser is refused unless its tag is a tab set. A tab
  set renamed to `.json` goes to the data viewer, and the user must rename it back, since uniterm's Open With lists
  only the data viewer for `public.json`. Leaves undone: the
  renamed-file direction of "the tag wins", and piped or pasted text, which have no entry point here.
- **The browser also claims `public.json` at the alternate rank.** Open With then lists the browser for any `.json`
  file, and the data viewer stays the owner, so the equal-rank test passes. The browser's reader refuses a `.json`
  file whose tag is not a tab set. This adds scope: a second claimed type, and a browser entry in every `.json` file's
  Open With list.
- **The router reads content.** It checks a JSON file's tag before matching. This contradicts UTERM-015's rule that
  the router resolves a file's type through the system, and would amend it.

Decision: the extension routes, and the tag validates. This narrows the settled "the tag wins" to what routing can
deliver. A file the browser receives whose tag is not a tab set is refused with a message. A tab set renamed to `.json`
opens in the data viewer as JSON, and renaming it back to `.uniterm-tabs` opens it as tabs. Piped or pasted text has
no entry point.

Rationale: the router types files through the system and reads no content, under UTERM-015. Reading every `.json`
file's tag would parse it twice, since the tag need not be the first key. A browser claim on `public.json` would list
the browser for every `.json` file, and one saved choice would send every later `.json` file to a refusal.

### How a program opens a tab file

Original question: how does a script or controller open a tab file? This is the open half of "The program call". The
save half is settled in "A program saves tabs through the user's save panel".

`uniterm open` and Launch Services already make a new pane beside the origin, and behave as the user's open. A Janet
script has no file open: its API has `open-pane`, `open-tab`, and `open-form`. A Janet controller without `subprocess`
cannot run `uniterm open`. One with it runs `uniterm open` outside a terminal session, where ADR-14 P13 keeps the
controller's own grant from covering the request. UTERM-018's "a script open never creates a pane" covers its unbuilt M5
file open, not `uniterm open`. A tab file always needs a new pane.

- **Build UTERM-018's script file open, and let it make a pane for an applet whose open always makes one.** The open
  runs through the router, as the user's does, under the path-read power and the pane-control power that already
  makes panes for `open-pane`. Every file type gets one program open path. This adds scope: it builds UTERM-018 M5
  and amends UTERM-018's "a script open never creates a pane".
- **A browser `open-tabs` command taking a path.** It reads the file under path-read and makes a new pane under
  pane-control, beside the program's source pane. Leaves undone: it is an open command for one applet that skips the
  router and saved choices, so other file types still have no program open.
- **No new open call.** Programs use `uniterm open` and Launch Services. Leaves undone: a Janet script, and a controller
  without `subprocess`, cannot open a tab file. That falls short of "Scripts and controllers can save and open tab
  files".

Decision: build UTERM-018 M5's script file open, and let it make a pane for an applet whose open always makes one. A
script or controller opens a tab file through it, routed as the user's open is, under the path-read power. The pane
needs pane control, and goes beside the program's source pane. It joins the run's owned group, as a pane from
`open-pane` does. Its tabs come from the file, not from the browser's `open` command, so they are not controller tabs.
Without pane control, the open fails with UTERM-018's not-found error. Because the pane loads a page, the open also needs
browser navigation, whatever the file holds, as a layout request seeding a browser URL does under UTERM-005. UTERM-018
M5 enforces this for every script open that would make a browser pane. Without it, the open is refused before any
sheet or pane. With both, the open behaves as the user's: the same tabs, the same selected tab
loading, and the same sheet past the tab threshold. A cancelled sheet replies with a distinct cancelled result. While
a threshold sheet from a script open is up in a window, a second script open into that window is refused, which bounds the questions a
program can raise under ADR-14 P15. UTERM-018 is amended to match. Amended 2026-11-22; see Decision Log.

Rationale: every file type gets one program open path, through the router and saved choices. Pane creation stays its
own power, as UTERM-018's 2026-11-21 ruling requires. A browser-only command would skip the router and leave other
file types with no program open. Browser navigation keeps a script that UTERM-003 denies network access from reaching
the network through a URL it wrote into a tab file, which ADR-14 P8 forbids.

Dissent left standing: the review's critic held that a script with pane control should make a pane for any file with
no capable pane, as the user's open does, not only for an applet whose open always makes one. The user chose the
narrower rule, and it is kept.

### A default shortcut for Save Tabs As

Original question: does Save Tabs As get a default key?

Decision: no default key. The File menu and the palette reach it, and the user can bind a key by its title in App
Shortcuts, which UTERM-013 lets win.

Leaves undone: no default key. Keyboard users reach the command through the palette or a remap.

Rationale: the window routes an enabled applet menu key before web content sees it. A default key would take that key
from every page in a browser pane. Cmd-S would break the save of web editors such as Google Docs, and Cmd-Shift-S that
of web IDEs that bind Save As. Cmd-Shift-S means Save As for a document that also has Save, and this command is an
export. A key can be added later with no contract change.

## Design Decisions (Open)

None.

## Risks

- **The extension, the format, and the tab-set identifier become published names** — likelihood: high, impact: medium.
  Mitigation: the in-file version lets the format change without renaming. A build reads every earlier version, and
  readers ignore unknown keys. `.uniterm-tabs` and `dev.uniterm.tabs` cannot change once files exist, and they are
  settled before any milestone ships. The imported `dev.uniterm.uri-list` identifier can change later. A stale saved
  choice is ignored, and `.uris` still routes through its extension.
- **A program's open loads a page signed in as the user** — likelihood: medium, impact: low.
  Accepted for `uniterm open` and Launch Services: a process running unsandboxed as the user can already read
  uniterm's cookies from disk, so the load gives it nothing new. Mitigated for scripts: a script's open needs browser
  navigation, so a script denied network access cannot reach it. Lazy loading limits each open to one page.
- **Finder may not pick uniterm for its own type** — likelihood: medium, impact: low.
  Mitigation: UTERM-015 registers every document type at the Alternate rank, so a double-clicked tab-set file might go
  to another app that edits `public.json`. M2 checks a double-click in Finder. When it fails, the follow-up is an
  amendment to UTERM-015 that gives uniterm's own exported types the Owner rank.
- **Saved URLs leak tokens** — likelihood: medium, impact: medium.
  Accepted: the user picks the file and its place, as for the layout file under UTERM-005. A file the user shares is
  shared by the user's choice.
- **A program call widens what a script can write** — likelihood: low, impact: high.
  Mitigation: a program's save shows the user's panel, so the user picks every file written and confirms any Replace.
  See "A program saves tabs through the user's save panel".
- **The browser's new type claim surprises an existing route** — likelihood: low, impact: low.
  Mitigation: the tab-set type is uniterm's own, and `text/uri-list` had no claimant. The drift test and the
  same-rank test catch a collision. A `.uris` file previously opened nowhere.
- **A huge file stalls the app** — likelihood: low, impact: medium.
  Mitigation: the file is bounded at 32 MiB and read off the main thread, and a file past 15 tabs asks first. A
  confirmed huge open still stalls on the tab bar and the layout save, which are filed bugs. Lazy loading bounds the
  network work.

- **The program decisions rest on ADR-15, which is proposed** — likelihood: medium, impact: medium.
  Mitigation: "A program-chosen open of a tab file", "How a program opens a tab file", and UTERM-018's script open cite
  it. M2 builds `uniterm open` of tab files on it, and M3 builds the script open and save. If ADR-15 changes before
  either starts, those decisions are reviewed again before it is scheduled.
- **`save-tabs` becomes a published controller command** — likelihood: high, impact: low.
  Mitigation: it travels in the browser's command schema, which stays at 0.0 under UTERM-063. A later change that alters
  a meaning takes a new command name, and the old name is refused by name. Its reply holds only a handle, and
  `wait-save` returns only a path, a cancel, or a write error, which leaves little to change.
- **M3 waits on a long chain** — likelihood: high, impact: low.
  Accepted: M3 starts after UTERM-018 M5, which waits on UTERM-004 M6, UTERM-005 M8, and UTERM-015 M4. M1 and M2 do
  not wait on it, so saving and opening ship first.

## Milestones

### M1: Save tabs in three formats

**Status:** NOT STARTED

- Save Tabs As… appears in the File menu and the palette for a browser pane, and nowhere else
- The save panel offers the tab-set type, `text/uri-list`, and Netscape bookmark HTML, with the tab-set type first and
  selected, and the extension follows the chosen format
- A saved tab-set file holds the `type` tag, the version, each storable tab's URL and title, and the selected tab
- A saved `.uris` file is valid `text/uri-list` per RFC 2483, with CRLF line ends
- A saved bookmark file imports into Safari and Firefox with each tab's title, and page-chosen titles and URLs are
  HTML-escaped
- The bookmark format shows in the save panel's control under a name that says it is a bookmark file, and declaring
  its type leaves how an `.html` file opens unchanged
- A tab that moved from an https page to a `blob:` page saves the https page
- A tab with no storable page is handled as "Tabs with nothing storable" settles
- A restored tab that never loaded saves its stored URL and title, after the same `storableURL` and title bounds
- A tab that an opened file filled with a `javascript:` URL, or a URL over 32 KiB, never writes it to any format
- The tab-set format's version is its own, independent of the browser's layout payload version, and a golden test pins
  the version-1 bytes
- A save of a large pane never blocks the main thread
- A second Save Tabs As while a write is in flight, or a pane that closes during the write, behaves as the map viewer's
  save does: one write runs at a time, and a failure alert still reaches the user
- A stored URL string that does not parse counts as nothing storable, and never traps
- A failed write raises an error alert naming the file, and leaves an earlier file intact
- The tab-set type is exported in `Info.plist` and conforms to `public.json`, and the drift test passes
- A UI test screenshot of the save panel shows the format control
- A tab with no storable page writes a tab-set entry with no `url`, keeping its bounded title when it has one
- A `.uris` or bookmark save from a pane with no storable tab is refused with a message, and writes nothing
- A save whose encoded file passes 32 MiB, in any format, is refused with a message naming the limit, and writes
  nothing

### M2: Open tab files back into a pane

**Status:** NOT STARTED

- A tab-set file and a `.uris` file each open into a new browser pane beside the origin, from File > Open, a drop on
  the Dock icon, and a drop on a pane, each by the route that entry point uses for other files
- A double-click in Finder opens a tab-set file in uniterm, or the result is recorded for the Finder rank risk
- Opened tabs carry the user's load origin, not the quiet origin of a restored tab
- A `.uris` file is read with CRLF or LF line ends, and its `#` comments are skipped
- A `.uris` file with no URLs, and a tab-set file with no tabs or a `selected` value out of range, are refused with a
  message
- A URL over 32 KiB is not stored in an opened tab, and a title is cut to 512 characters
- The imported `text/uri-list` type conforms only to a text type no other applet claims, and a `.uris` file whose
  preferred type comes from another app still reaches the browser through its extension
- The new pane holds every listed tab in order, only the selected tab loads, and each other tab loads when first
  selected
- A tab-set file round-trips: saving, then opening, gives the same URLs, titles, and selection
- A URL the scheme policy refuses keeps its tab, shows `about:blank` with an explanation, and keeps its URL
- A file with the tab-set extension whose tag names another type is refused with a message
- A tab-set file renamed to `.json` opens in the data viewer, and renamed back to `.uniterm-tabs` opens as tabs
- A program's open of a tab file through `uniterm open` makes the same pane and tabs as File > Open, and loads the
  same selected tab
- A file past the tab threshold shows one sheet before any pane exists, naming the file and the count and listing the
  first URLs with "and N more". Cancel makes no pane, and the same file from `uniterm open` asks the same sheet
- A version newer than the build is refused with a message naming the version, and every earlier version opens
- A version-1 file with an unknown top-level key and an unknown per-tab key opens with no error, and the keys are
  ignored
- A file over 32 MiB is refused with a message naming the limit, and only the limit plus one byte is read
- The file is read and parsed off the main thread by the browser's prepare step, and no pane exists until the read
  and any sheet are done. The factory takes the prepared tabs and never reads the file again
- A Finder open with no window open still shows the threshold question, app-modal, and Cancel makes nothing
- Threshold sheets raised by repeated `uniterm open` runs count against UTERM-015's bound on waiting questions
- A text viewer, data viewer, and map open still route as before, with no prepare step
- A file of 16 tabs shows the sheet, and a file of 15 does not
- A batch of more than 10 files from `uniterm open` shows the batch sheet first, then one tab sheet per tab file past
  the threshold, and an approved program skips neither tab sheet
- The sheet's URLs pass the same control and bidirectional character escaping as the open approvals, and each is
  shortened for display
- An entry with no `url` opens as a blank tab with its title, and keeps its position and the selection
- A plain `.json` file still opens in the data viewer, and an `.html` file opens where it did before

### M3: Program save and open

**Status:** NOT STARTED

Starts after UTERM-018 M5, which builds the script file open.

- A program's `save-tabs` shows the user's Save Tabs As panel for its target pane, and the file the user saves holds
  the same content as the user's own save
- `save-tabs` replies with a handle once the panel shows, before the user picks. `wait-save` on that handle returns
  `saved` with the path written, `cancelled`, or `failed` with the write's error, and a second `wait-save` returns the
  same outcome
- A write that fails, such as into a read-only folder, makes `wait-save` return `failed`, and the user's alert still
  shows
- A revocation, run end, or pane close while the panel is up dismisses it, writes nothing, fails a pending `wait-save`
  as ended, and frees the handle
- A revocation during the write lets the file be written, fails a pending `wait-save` as ended, and never reports the
  save as undone
- `discard-save` on an open panel dismisses it and writes nothing. `wait-save` on a discarded or freed handle replies
  with a structured error
- A 33rd save handle on one connection drops the oldest settled one
- A program without pane control over the target pane, or whose target pane is outside its targets, is refused with
  an error that names what is missing, and no panel shows
- A second `save-tabs` while a panel is up in that window is refused
- A script or controller with path-read, pane control, and browser navigation opens a tab file through UTERM-018's
  script file open, into a new browser pane beside its source pane, with the same tabs, load, and sheet as the user's
  open. The pane joins the run's owned group
- The same open without pane control fails with the not-found error, and makes no pane
- The same open without browser navigation is refused before any sheet or pane, with an error naming the power
- A script open of a file past the threshold checks its powers before the sheet shows, and a cancelled sheet replies
  with a distinct cancelled result
- A second script open into a window while a script open's threshold sheet is up is refused
- After the user confirms the threshold sheet, path-read, pane control, browser navigation, and the source pane are
  checked again
  before the pane is made, per ADR-14 P11. Any that was revoked or closed meanwhile makes no pane and replies with an
  error
- A script open with no room beside its source pane fails before any sheet shows
- A file whose selected entry has no `url` still needs browser navigation to open from a script
- Revoking pane control or browser navigation stops further calls
- An older uniterm answers the new command with a clear error that names the unknown command, per UTERM-063

## Decision Log

- 2026-11-22: Drafted from the "Browser: save tab URLs to a file" idea. The user chose a uniterm tab-set JSON as the
  default, with `text/uri-list` and Netscape bookmark HTML offered through the save panel's format control. The user
  chose an extension plus an in-file `type` and `version` tag, with the tag winning, and a format for tab sets only.
- 2026-11-22: The user chose to open tab-set and `text/uri-list` files back, with Netscape HTML export-only. The user
  chose a new pane with lazy loading for an opened file, and URLs written unchanged.
- 2026-11-22 (addition): The user added a program call for saving and opening tab files. It brings in an ADR-14 power,
  a wire command under ADR-13, and the UTERM-018 rule that a script open never creates a pane. Its shape is open.
- 2026-11-22 (autonomous): The draft's critique found that a tab's stored URL and an opened file's refused URL skipped
  the save filter, so a `javascript:` URL from a `.uris` file could reach a bookmark file. "Saved values reuse the
  layout's filters" now filters every URL and title at save time and bounds them on open. It said "each tab saves its
  committed URL through `BrowserDescription.storableURL`" and "A tab that has not loaded since restore saves its stored
  URL and title", with no filter on the stored URL.
- 2026-11-22 (autonomous): The critique found the map viewer's write runs off the main thread, and a tab set has no
  size bound. "The write is atomic and bounded" now writes off the main thread. It said "The write is small and
  bounded, so it may run on the main thread under ADR-08."
- 2026-11-22 (autonomous): The critique found that the router cannot read the tag, so a renamed tab-set file never
  reaches the browser, and that a program's `uniterm open` of a tab file loads a page signed in as the user. Both go
  against settled choices, so they became the open questions "How the tag wins on open" and "A program-chosen open of
  a tab file". It also found that `text/uri-list` has no system type, that adding a field could make older builds
  refuse files, and that Finder may not pick uniterm. These joined the open questions and Risks. Its edge cases were
  routed to M1 and M2 checks.
- 2026-11-22 (autonomous): The re-check found four misstatements in the new open questions. The "loads no tab" option
  conflicts with ADR-15 rather than fitting it. "Needs browser navigation" had two readings, now two options, one of
  them an addition. The "no new open call" candidate loads eagerly and is capped, so it gained a leaves-undone line.
  "Tabs with nothing storable" repeated a settled choice as a candidate, so its two skip options merged. The first
  "How the tag wins on open" option no longer offers Open With as a way back. Its concurrency, parsing, and `.uris`
  type edge cases were routed to M1 and M2 checks.
- 2026-11-22 (autonomous): The third pass confirmed those fixes. It found that "A program cannot open a tab file
  through these paths" also refuses the user's own shell and `/usr/bin/open`, so that option gained a leaves-undone
  line. This fix was not re-checked, since the critique loop's three passes were spent.
- 2026-11-22: Review start: 3 milestones, 9 settled decisions, 7 risks, no `**Live after:**` lines or row gates, 8 open
  questions; one scope statement, that the format holds tab sets only. Baseline is the commit "Label what UTERM-049's
  refuse-program-opens option refuses". The user asked for an autonomous review of every open question.
- 2026-11-22 (autonomous): The tab-set format uses `.uniterm-tabs` and `dev.uniterm.tabs`, and its in-file tag is that
  identifier. `text/uri-list` is imported as `dev.uniterm.uri-list`. A name in the IETF's namespace would be coined, not
  shared. "The tab-set format carries an extension and an in-file tag" gave `uniterm.tabs` as an example tag. It now
  points at this decision. The published-names risk now says the `text/uri-list` identifier can change.
- 2026-11-22 (autonomous): Version 1 of the tab-set format holds URL, title, and the selected tab only. Readers ignore
  unknown keys, and only a change an older reader would misread bumps the version. An M2 check pins the unknown-key
  rule.
- 2026-11-22: The user chose that a program's open of a tab file behaves as the user's, and that a file past a tab
  threshold asks once in a sheet before anything is made, for every source. A launchd job with no Full Disk Access
  read uniterm's cookie file, so a program running as the user gains nothing from a signed-in load. "An opened file
  makes a new pane and loads lazily" said "An open a program chose, through `uniterm open` or Launch Services, still
  loads the selected tab today", and its rationale said the open is bounded "without a cap or a prompt". The risk of a
  program's signed-in load is now accepted at low impact. "Bounds on opening a file" now settles the threshold.
- 2026-11-22 (autonomous): A tab with nothing storable is written as an entry with no `url`, keeping its title. `url`
  is optional from version 1. `.uris` and bookmark saves leave it out, and a save in those formats with nothing
  storable is refused. Skipping tabs would have needed a selection rule and could write an empty set the open refuses.
- 2026-11-22 (autonomous): The tab threshold is 15, as Firefox and Chrome use for the same operation. Tab files are
  bounded at 32 MiB, read off the main thread before any pane exists, and Save Tabs As refuses a file past the same
  limit. No tab ceiling applies to a confirmed open. A confirmed huge open still stalls on two filed bugs. The open now
  needs a read step before the applet's factory. The critic ranked 15 first and the app's batch threshold of 10 second.
- 2026-11-22 (autonomous): A program saves tabs through a `save-tabs` command that shows the user's Save Tabs As panel,
  under the ask-user power and ADR-14's targets. No path-write power is added. "The program call" is now "How a program
  opens a tab file", the open half. The risk of a program call widening writes drops to low likelihood.
- 2026-11-22: The user chose that the extension routes a file and the tag only validates what the browser receives.
  "The tab-set format carries an extension and an in-file tag" said "The tag decides what the file is. When the
  extension and the tag disagree, the tag wins." Its rationale said the tag keeps "a renamed file, a piped script
  output, or pasted text self-describing".
- 2026-11-22 (addition): The user chose that programs open tab files through UTERM-018 M5's script file open, which may
  make a pane under pane control for an applet whose open always makes one. UTERM-018 is amended to match, and M3 now
  starts after UTERM-018 M5. It brings in building UTERM-018 M5 and amending its "a script open never creates a pane".
- 2026-11-22 (autonomous): Save Tabs As has no default key. Applet menu keys run before web content, so any default
  would take the key from pages, and Cmd-Shift-S means Save As for a document with a Save.
- 2026-11-22: The coherence review found that a Janet script denied network access could open a tab file it wrote and
  make uniterm load a URL it chose. The cookie-file reasoning holds only for unsandboxed processes. The user chose that
  a script's open of a tab file needs browser navigation, as a seeded layout URL does under UTERM-005. "A program-chosen
  open of a tab file" said "No gate, refusal, or approval wording is specific to tab files or to programs".
- 2026-11-22 (autonomous): The coherence review found that `save-tabs` rested on the ask-user power, which means a
  Questions form and passes for most programs. It now needs pane control, and the user's pick in the panel authorizes
  the write. "Scripts and controllers can save and open tab files" said "Writing the user's files is not a C1 effect
  under ADR-14, so the save needs an authenticated requester and an explicit, revocable grant under P7". The save
  decision said "The command needs the ask-user power, since it puts the user in front of a panel".
- 2026-11-22 (autonomous): The coherence review's other fixes. A pane a script open makes joins the run's owned group,
  and its tabs are not controller tabs. A second program open while a threshold sheet is up is refused, as ADR-14 P15
  asks. The read step before the factory is now an optional prepare step in the applet contract: the factory takes the
  prepared source and never reads the file again. "Bounds on opening a file" said "The browser's open reads and parses
  the file before the router asks the applet's factory for a pane". Two risks joined: the reliance on proposed ADR-15,
  and M3's dependency chain. The critic's dissent on the narrower script-pane rule is kept in the settled entry.
- 2026-11-22 (autonomous, provisional): `save-tabs` supersedes in part UTERM-005's "Control" rule that every browser
  command needs a browser permission and acts only on the controller's own tabs. UTERM-005 is implemented, so its text
  is not edited until the user confirms this at the review gate. The browser-navigation gate for a script open now
  lives in UTERM-018 M5, whatever the file holds. The one-sheet-per-window bound covers script opens only.
- 2026-11-22 (autonomous): Risk review. Every risk carries a likelihood, an impact, and a mitigation or acceptance. The
  `save-tabs` command joined as a one-way door, mitigated by its versioned schema. No risk is high likelihood and high
  impact. The proposal loop converged on its third pass.
- 2026-11-22: No decision in this review earns an ADR. The browser-navigation gate on script opens applies ADR-14 P8.
  The format, extension, and identifiers are mechanisms, not invariants. The threshold sheet and the prepare step each
  shape one component.
- 2026-11-22: Review gate: kept all. The user confirmed that `save-tabs` needs pane control and saves every tab,
  superseding in part UTERM-005's "Control". UTERM-005 carries the marker.
- 2026-11-22: The user accepted the proposal.
- 2026-11-22: Scheduled as UTERM-049 M1-M3 in queue.md.
- 2026-11-23: Bug triage found that `save-tabs` held its reply until the write, against ADR-11. A revocation during
  the write would fail the reply after the file stood, and the program could save again. The user chose that
  `save-tabs` replies at once with a handle, over settling the reply when the user confirms, which would hide a failed
  write from the program. The user also chose it over treating the panel as a read, which needs a promise the spec does
  not give. "A program saves tabs through the user's save panel" said "The reply is the path written, or a cancel".
  M3 checked "The reply names the path written, or says the user cancelled". The `save-tabs` risk said "Its reply
  holds only a path or a cancel".
- 2026-11-23 (autonomous): The handle's mechanism follows UTERM-022's `wait-form`. `wait-save` reads the outcome and
  `discard-save` frees the handle. The save has no completion event, since remote callers get no applet events. Caps
  match other ADR-11 handles. A revocation during the write lets it finish and fails the wait as ended. M3 gained
  checks for each outcome, the interruptions, discard, and the cap.
- 2026-11-26: Its row moved after UTERM-018 M3-M5, which it depends on, when UTERM-018's row split around UTERM-062.
- 2026-11-27: Brought in line with UTERM-063 at the user's direction. The "save-tabs" skew passage said a newer program
  "gets the older build's answer for an unknown command or schema version, a clear error under ADR-13". The risk said "a
  later change bumps the version and an older or newer peer gets a clear error under ADR-13". The M3 check said "an
  unsupported schema version or an unknown command". They now say the browser schema stays at 0.0, a changed meaning
  takes a new command name, and an unknown command is refused by name. The tab-set file's own version is not an
  external version and is unchanged.

## References

- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): an opened file only makes tabs, and loads lazily
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): an applet binds keys only for its own
  actions
- [ADR-05](../adr/ADR-05-applet-lifecycle-events-and-applet-responses.md): the applet owns its tabs
- [ADR-06](../adr/ADR-06-layout-file-versioning-and-schema-ownership.md): the version pattern this format follows
- [ADR-08](../adr/ADR-08-ui-responsiveness.md): the save's write runs off the main thread
- [ADR-11](../adr/ADR-11-deferred-applet-replies-never-hide-effects.md): `save-tabs` replies with a handle
- [ADR-13](../adr/ADR-13-outside-wires-stay-compatible-across-versions.md): the program call's wire versions
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): P7 grants, P8 separate powers, P15 bounded reach,
  C1 effects that need no grant
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md) (proposed): a program's save and open behave as the
  user's
- RFC 2483, `text/uri-list`: https://datatracker.ietf.org/doc/html/rfc2483
- IANA `text/uri-list`: https://www.iana.org/assignments/media-types/text/uri-list
- Netscape Bookmark File Format:
  https://learn.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/platform-apis/aa753582(v=vs.85)
