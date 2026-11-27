# UTERM-032: Input File Granted at Run Time

**Status:** accepted
**Created:** 2026-11-15
**Updated:** 2026-11-27

## Dependencies

- UTERM-015, for the path-reading power, its checks, and its approval lifetimes, built in its M4
- UTERM-003, for `uniterm run` and its argument handling
- UTERM-004, for controller runs, the approval panel, and revocation
- UTERM-021, for declared files and the `declare-permissions` spelling

## Impacts

- UTERM-030 — "Slide images": slide images load from the folder this proposal grants.
- UTERM-029 — "Input kinds and host functions": amends this proposal so a PDF or a folder may be the input, under
  a later edition of the `input-file` kind, with four host functions to read them. Its PDF pages count as slide images under this grant.
- UTERM-025 — "How it starts": the presenter takes its deck as an argument, under this proposal.
- UTERM-004 — "Permission scopes and approval flow": supersedes in part its rule that approvals hold typed authority
  ceilings, not exact launch inputs, and that arguments are never part of a remembered scope. A remembered folder for
  slide images comes from a run's argument. UTERM-004 is implemented, so it gains a "Superseded in part by UTERM-032"
  marker when this proposal is accepted.
- UTERM-004 — M6's approval panel: it gains a line naming the input file's folder when no remembered approval covers
  the folder.
- UTERM-004 — "Permission scopes and approval flow": Allow once keeps the input folder standing for the run, beside
  Janet capabilities. See "Approval lifetimes".
- UTERM-021 — "The declaration's data shape": a declared file gains the `input-file` permission kind, and each
  permission meaning names where its kind may appear.
- UTERM-034 — "Who reads the script": once it lands, the command reads a declared script's bytes and sends the
  declaration after them, with no snapshot. This proposal's "the snapshot's declaration" then means the declaration in
  those bytes, and its folder rides with that declaration. UTERM-034 M1 amends the text when it builds the change.
- UTERM-021 — "Trust records for files": supersedes it in part. UTERM-067 then puts every approval in one store, so a
  file policy that holds a remembered folder lives there too. UTERM-021 carries a "Superseded in part by UTERM-032"
  marker. Amended 2026-11-26; see Decision Log.
- UTERM-015 — M4's protected-location list: this proposal's M2 gives each entry a stable name, pinned to its extent by
  the list's test. An entry whose extent changes takes a new name. Remembered input folders record these names.
- UTERM-004 — "Permission scopes and approval flow": a controller run's startup denial covers its verified version and, for a
  run with an input folder, that folder only. Such a run, when covered, is admitted before any denial is checked. See
  "What a denial covers".
- UTERM-015 — "How the path-reading power is granted": the input folder is a kind of its own, not a path-reading scope.
  It reuses that section's protected-location list and coverage rule, and grants no path read under the power.

## Summary

A declared script may name one argument as its input file, such as the presenter's deck:
`uniterm run presenter.janet ~/talks/demo/deck.md`. uniterm reads the file and hands its text to the script. After the
user approves, the script may have the text viewer load images from that file's folder. The script itself holds no file
access.

This is a required prerequisite of the presentation controller, UTERM-025, through its deck and slide images.

## Motivation

A declared file states its powers as fixed text inside the file. A path-reading scope written there names one folder,
for every run. A presenter is started on a different deck each time, usually in Documents or Desktop. A fixed scope
cannot follow it.

The alternative is Janet's `:fs-read`, which reads any file the user can. That is far more than a presenter needs.

## Design Decisions (Settled)

### The deck is an argument

Decision: a script's declaration may mark one argument as its input file. The user names the file when starting the
run. uniterm reads it and gives the script its text. After approval, the app grants the file's folder for the run.

- The argument still belongs to the script, per `uniterm run`'s rule that everything after the script's file is the
  script's. The script learns the granted folder from uniterm, so it knows the folder it may pass to the viewer.
  See "How the script names the base folder". Amended 2026-11-16; see Decision Log.
- One name drives both the text and the folder, so a deck cannot mismatch its images.
- A script that declares no input file runs as it does today.

Rationale: the user names the deck as an argument, the way any command takes a file. The script gets the text it needs
and no file access.

### Approval shows the folder

Decision: the approval sheet names the input file's folder. That is where the authority comes from.

Rationale: a name on a command line can come from a program, per UTERM-015's rule that a program can choose what a
command line names. So the run's argument is not the user's act by itself. The sheet is.

### The grant covers slide images only

Decision: the folder grant lets the text viewer load a slide's images from inside the folder, under UTERM-030. A PDF
page named under UTERM-029 "PDF page references" is a slide image. It grants no other path read, even after other path
commands land under UTERM-015 M4. Amended 2026-11-17; see Decision Log.

Rationale: the presenter needs only images. A wider grant would widen silently as other applets gain path commands.

### Approval lifetimes

Decision: the user chooses Allow Once, Allow for This Run, or a remembered trust choice, as UTERM-021 offers a declared
file. A remembered approval covers the same folder, or one inside it, on later runs, per ADR-09's reuse rule. A
different folder asks again.

- Allow Once and Allow for This Run grant the folder alike, for that run only. Today Allow Once keeps only Janet
  capabilities standing, and each other power asks on use. An image load has no question of its own, so the folder
  joins the capabilities as a power Allow Once keeps standing for the run.

Amended 2026-11-16; see Decision Log.

Rationale: rehearsing a talk runs the same deck many times. Asking every run trains the user to approve without
reading, which ADR-09's Context warns against. The user chose this.

### Protected folders

Decision: UTERM-015's protected-location rule applies as written. A folder inside Documents keeps its access, and the
sheet names Documents.

Rationale: UTERM-015 "How the path-reading power is granted" removes only protected locations inside a scope, and names
any protected location the scope lies in.

### Version skew

Decision: the `input-file` kind and the folder crossing from the command to the app are new. ScriptWire is at 0 under
UTERM-063 and does not bump, so they land in place after UTERM-063 M2. Amended 2026-11-27; see Decision Log.

- A new command with an old app, or the reverse, fails before any effect. The side that did not change refuses the
  message it does not know by name, and a swapped bundle is caught by the command's identity check, which says to
  relaunch uniterm. The command is the bundle's own, so a relaunch heals it.
- An older build refuses a declared file that declares `input-file`, since it does not know the kind.
- A remembered approval that holds a folder lives in the one trust store, per "The stored approval". A build with
  UTERM-067's reader that cannot read it keeps it unread, and its other approvals keep working. A build from before
  that reader behaves as UTERM-067 "Version skew" states. Amended 2026-11-26; see Decision Log.

### Which argument is the input file

Original question: a position, the last argument, or a named flag such as `--deck`, and what happens when the argument
is missing. The choice is a published contract under UTERM-021, which refuses unknown fields.

Decision: the input file is always the first argument after the script's file. The declaration only marks that the
file takes one. Options and other arguments come after it, and remain the script's to parse:
`uniterm run presenter.janet deck.md --start 3`.

- The snapshot's declaration decides whether a run has an input file, per UTERM-021 "Where the declaration is read".
  The command checks the argument after it parses the snapshot, and before it sends the declaration.
- A missing first argument refuses the run there, with a usage message that names the input file. Nothing reaches the
  sheet.
- A script that declares an input file cannot run without one, so it cannot print its own help without a file.

Rationale: a fixed operand is how `uniterm run` itself reads its own arguments: a fixed operand, then everything else
belongs to the script. The command and the script cannot disagree about which argument it is. The last argument stops
being the file once a script adds a trailing option. A declared index is a knob no caller needs. A declared flag has the
command and the script parse the same arguments separately. A script option that takes a value, such as
`--title --deck real.md`, then makes them name different files. That breaks "One name drives both the text and the
folder".

### How the text reaches the script

Original question: whether the command opens the file onto the script's stdin, or a host call returns the text.

Decision: the command opens the file once, with the invoker's own access, and hands its text to the script through a
named binding in the uniterm module. The script's stdin stays the invoker's.

- The command opens the file after the snapshot's declaration marks an input file, and before it sends the
  declaration. A missing file, a non-regular file, a FIFO, a device, or a path under `/dev` is refused there, before
  anything blocks and before any sheet names it. The open never blocks and never makes a terminal the controlling
  terminal.
- The text, the canonical path, and the folder all come from that one open. The folder is the parent of the file's
  canonical path. The open descriptor must be the file that canonical path names, or the run is refused.
- The command sends the folder to the app beside the declaration report, in the same in-place ScriptWire
  change as "Version skew". The app refuses a declaration that marks an input file and arrives with no folder, and a folder that
  arrives with no mark.
- The read runs in the command's process, so it borrows none of uniterm's macOS privacy grants.
- Once the `input-file` kind takes the new inputs, a PDF or a folder may be the input, per UTERM-029 "Input kinds and host functions". A
  folder is not refused as non-regular there. The command passes a PDF's open descriptor to the app instead of reading
  it, and lists a folder through its descriptor. The UTF-8 check and the size cap apply to text input only. Amended
  2026-11-17; see Decision Log.

Rationale: a read in the invoker's process gives the script exactly what the invoker could read. A host call would
have the app read a path a program chose, with uniterm's grants. With a remembered folder, any program could then run
the approved script on a file under that folder and get its text, with no sheet. UTERM-015 "The path-reading power"
forbids that. It would also put an unbounded read, such as an iCloud-evicted file, in the app, against ADR-08. Putting
the file on stdin binds the text to its folder too. But the user corrected the earlier stdin text. A script that waits
on `getline` would also read a line of the deck, and every child process would inherit the deck as its input.

### How the script names the base folder

Original question: the script cannot reliably name the canonical folder UTERM-030 checks. A relative argument has no
folder part, and `os/realpath` needs `:fs-read`. Either the host fills in the base folder from the run's grant, or a
host call returns the canonical input path.

Decision: the command gives the script the granted folder through a binding, beside the text. It is the parent of the
input file's canonical path. "Names" spells it. The script passes an absolute base folder to `show-markdown`, and the viewer checks that
it lies inside the grant. UTERM-030's
"Slide images" stays as written.

Rationale: the folder flows explicitly through `show-markdown`, as the project's applet attribute rule asks. If the host
filled in the folder from the run, `show-markdown` would mean different things in runs with and without a grant. That
is hidden state from the run. A host call that returns the path would have the app resolve a program-chosen path,
before approval or after it. After approval, a rename between the two reads could leave the text from one file and the
folder from another. The command already holds the canonical path from its one open.

### The stored approval

Original question: a remembered folder needs its own stored record kind, apart from UTERM-015's path-reading power,
since UTERM-015 refused one stored type with two meanings. Also its coverage rule, with UTERM-015's protected-location
subtraction, so a remembered `~` does not cover a deck under `~/Documents`.

Decision: the input folder is a permission kind of its own, held in the run's requested permissions. A remembered
policy that holds one lives in the one trust store, `policy.json`, beside every other approval, as UTERM-067 "One store
holds every approval" sets. Amended 2026-11-26; see Decision Log.

- The run's request holds the folder like any other permission. So the review key, coverage, merging, and the "new
  since you trusted it" lines work on it as they do on every other power. A run that asks only for a folder still gets
  a sheet.
- The kind is stored only. The meanings table marks it so, and the one reader of declarations and `controller.json`
  refuses it there. The stored scope type's rule that arguments are never part of it gains this one exception.
- Coverage: the requested canonical folder lies inside an approved one, and lies in no protected location that the
  approved folder does not lie in or name. Paths compare as APFS compares names.
- Each stored folder records, by stable name, the protected locations inside it that its sheet excluded. A remembered
  folder covers a request only while every recorded name is still on this build's list. A name the build does not know,
  or one the list dropped, makes that folder ask again. A location added to the list later is excluded at once, since
  coverage reads the current list. The kind's edition never changes with the list.
- An entry of UTERM-015's list whose extent changes, wider or narrower, takes a new name. A recorded name then never
  covers more than the sheet showed, on a newer build or an older one.
- A protected location added later that encloses a remembered folder leaves it covering, per UTERM-015's rule for a
  scope that lies in a protected location. The window names that location.
- A file policy that holds a folder is one entry in the store, naming its artifact kind, under the store's one lock.
  A build that cannot read it keeps it unread and grants nothing from it, per UTERM-067.
- Each policy holds at most a fixed number of folders. A remember past the cap is refused with a message that names
  the policy, and the run is offered Allow once and Allow for This Run. The store's own bound is UTERM-067's, and never
  asks the user to revoke approvals.
- The Controllers & Permissions window lists each remembered folder under its policy, with the protected locations it
  lies in or names. Revoking is per policy, as today.

Rationale: a stored kind inside the request keeps every consent path seeing the folder. A field beside the request
would leave a run that asks only for a folder admitted as asking for nothing, with no sheet. Two runs on different
folders would also share one review, so one Trust would admit both. A store of its own is not needed: under UTERM-067
a build that cannot read a folder policy skips that one entry and keeps the rest, and uniterm is pre-v1, so builds
from before that reader do not constrain the format. A folder file bound to its policy by timestamp can bring back a
folder an older build revoked, since a policy record has no room for a stronger binding. A per-folder revoke that ends one live grant would be new mechanism
beside the per-policy revoke. The cap's message names the policy instead. An edition raised with the list would
ask again for every folder policy, and make a build that lacks the newest edition keep every folder policy unread. Every power of every folder policy
would then stop working there. Recording names instead asks again only for the folders a change touched.

### What a denial covers

Decision: a startup denial of a run with an input folder covers that file version on that exact folder only. Folders
compare as APFS compares names. For a run with an input folder, a remembered approval that covers it admits it before
any denial is checked. Other runs keep today's order.

- A run on a different folder gets a sheet. A run with no input folder is denied as today, by version.
- A program can raise one sheet per folder it names, bounded by the 32 connections the listener accepts. It can already
  do as much by changing one byte of the script, which makes a new version.

Rationale: a denial keyed by version alone lets a program turn off the user's trust. The program starts the
presenter on an unknown folder, and Deny is the sheet's default button. The user's own remembered run on their deck is
then refused until Ask Again, since the denial is checked before coverage today. Keying the denial to the folder covers
exactly what the user saw.

### Calls without an input file

Decision: `uniterm/input-text` and `uniterm/input-folder` raise an error in every run that has no input file. Each
error says what to do next.

- In a declared file that does not declare `input-file`, the error names the undeclared permission, per UTERM-021
  "Undeclared powers are refused".
- In a package, it says a package cannot take an input file.
- In an undeclared file or a REPL, it says only a declared file takes an input file, and names the `input-file`
  kind the call needs. Amended 2026-11-17; see Decision Log.

Rationale: no caller is served by nil. A declared run with an input file always has one, since a missing argument
refuses the run. Every other run can never have one. A nil would make a forgotten declaration run as if the deck were
empty, and fail later in the script's own parsing.

### Names

Original question: the declaration field's spelling under UTERM-021, the names of the two bindings, and the sheet's
wording. The mark is either a header field or a permission kind. A header field needs the C declaration parser to type
a new header key, and UTERM-021 "The declaration's data shape" says a header change adds a `:format` key. A permission
kind joins the meanings table that declarations and `controller.json` share, so `controller.json` would accept it
unless refused there.

Decision: a declarable permission kind, two host functions, and a sheet line built from the folder alone.

- A file declares `{:kind :input-file}`, with no other fields. The app replaces it with the stored folder
  kind of "The stored approval" when it validates the declaration. The declarable kind never enters a request, a review
  key, or a store.
- Each permission meaning names where its kind may appear: a package, a file, or a store. One rule in the reader then
  refuses `input-file` in `controller.json`, and the folder kind in any declaration.
- `(uniterm/input-text)` and `(uniterm/input-folder)` return the text and the folder the grant holds. No function
  returns the file's own path. UTERM-029 adds `input-kind`, `input-name`, `input-pages`, and
  `input-images`. `input-name` returns the canonical base name, which a generated slide needs to name a PDF page.
  Amended 2026-11-17; see Decision Log.
- The sheet line reads "Let the text viewer show images and PDF pages from /Users/me/talks/demo or a folder inside it,
  in panes it controls", for every input kind. UTERM-015's line naming any protected location the folder lies in
  follows it. The stored folder kind keeps its edition.

Rationale: a permission kind keeps the declared list the whole set of powers, as the lint and UTERM-021's refusal rule
expect. A header key would grant a folder the list never names. As written, it would also need a boolean, which the
declaration grammar does not allow. One kind for both the declaration and the store would need a field rule inside the
kind, refusing a folder in a declaration and requiring one in a store. Two kinds put that rule in where each kind may
appear.
Functions follow the existing host API. A misspelled function fails as an unbound symbol, where a misspelled struct key
reads as "no input file". A dynamic binding reads as nil in a fiber with no environment. `input-folder` hands the script
the grant's own string. A declared file loads no path library, and a hand-rolled dirname gets a deck at the volume root
wrong. The sheet line comes from the permission alone, so it reads the same in the Controllers & Permissions window. A
line naming the deck would need the file name stored in the permission.

## Design Decisions (Open)

None.

## Risks

- **An input file is a new approval contract** — likelihood: high, impact: medium. Users and tools would depend on how
  it is declared and shown. Mitigation: version the declaration under UTERM-021, and show the folder in the sheet.
- **A user names a deck in too broad a folder, such as `~`** — likelihood: medium, impact: medium. Mitigation: the sheet
  shows the folder, UTERM-015's protected-location rule still applies, and the grant covers slide images only.
- **A program-started run reuses a remembered folder** — likelihood: medium, impact: high. Any process can run
  `uniterm run` with a path under a remembered folder. Mitigation: the command reads the text with the invoker's own
  access, per "How the text reaches the script", so the program gets nothing it could not read itself. The grant shows
  images in panes and returns nothing to the script, and it covers slide images only.
- **The stored approval changes shape** — likelihood: high, impact: medium. Remembered scopes start holding a value from
  a run's argument. Mitigation: a stored-only kind that records the protected locations its sheet showed, kept per
  entry under UTERM-067. See "The stored approval".
- **An older build cannot see or revoke a remembered folder** — likelihood: high, impact: low. A build that cannot
  read a folder policy keeps it unread. Mitigation: it grants nothing there, the window counts it, and a build that
  reads it lists and revokes it. Amended 2026-11-26; see Decision Log.
- **The recorded protected-location names are new stored data** — likelihood: high, impact: medium. Every later build
  must read them. Mitigation: an entry a build cannot read costs only that entry, per UTERM-067, and a list change never
  makes one unreadable.
- **The work it builds on is unbuilt or still in design** — likelihood: high, impact: medium. UTERM-015 M4 owns the
  protected-location list and is not started. UTERM-030 is a draft, and owns the image loads. Mitigation: both
  milestones start after UTERM-015 M4, and image checks stay with UTERM-030 M2.

## Milestones

### M1: An input file granted for one run

**Status:** NOT STARTED

- Starts after UTERM-015 M4, for the protected-location list
- A script that declares an input file gets the named file's text and no file access of its own
- The approval sheet names the file's folder and any protected location it lies in, and the run starts only after
  approval
- A missing, non-regular, FIFO, or `/dev/fd` input is refused before anything blocks
- A file that gains the input-file mark between the command's first read and the snapshot is checked and opened by the
  snapshot's declaration
- An argument in the input position that starts with `-` is refused with a message that the input file comes first
- Opening a tty node as the input file never makes it the controlling terminal
- A deck reached through a hard link or a symlink grants the folder of its canonical path, and a descriptor that does
  not match that path refuses the run
- An input file over a stated size cap is refused before the declaration is sent, with the cap in the message
- An input file that is not UTF-8 is refused in the command, with a message
- The app refuses a declaration that declares `input-file` and arrives with no folder, and a folder that arrives with
  no such declaration
- `input-file` in `controller.json`, or the folder kind in any declaration, is refused by the placement rule
- The input functions raise the error "Calls without an input file" sets for each kind of run, and `uniterm lint`
  counts a call to them as using `input-file` and reports one made without declaring it
- Allow Once and Allow for This Run both put the folder in the run's grant for that run only
- Revoking the run removes the folder from its grant, and the grant ends with the run
- A restored pane never starts the script and holds no folder grant
- A startup denial covers that version on that exact folder, compared as APFS compares names, and a run on another
  folder gets a sheet. The Ask Again row names the folder, escaped as the sheet line is
- Until M2, a run with an input folder is offered Allow Once and Allow for This Run only. No folder kind is ever
  written to the trust store
- The sheet's folder line escapes the program-chosen path
- The grant covers the deck's own canonical folder and grants no path read under UTERM-015's power. UTERM-030 M2 owns
  the image loads and their checks

### M2: Remembered input folders

**Status:** NOT STARTED

- Starts after M1
- Each entry of UTERM-015's protected-location list carries a stable name, and the list's test pins each name to its
  extent, so a change of extent fails the test until the entry is renamed
- A build that does not know a recorded name keeps that folder, with its names unchanged, when it rewrites the store
- A protected location added later that encloses a remembered folder leaves it covering, and the window names it
- A remembered approval covers a later run on the same folder, or one inside it, and a different folder asks again
- A remembered `~` does not cover a deck under `~/Documents`
- Folder coverage holds against case variants of the same path
- A remembered folder whose recorded protected-location name this build does not know, or the list dropped, asks again.
  A location added to the list later is excluded from it at once
- A run a remembered approval covers is admitted even after a denial of a narrower folder
- A run whose covering policy is removed during admission still meets the denial check before any sheet
- A file policy that holds a folder is one entry in the trust store, naming its artifact kind, and a build that cannot
  read it keeps its other approvals and its Trust choice
- Revoking a policy mid-run removes the folder from the live run's grant
- A remember is offered only when the trust store is writable
- A remember past the folder cap is refused with its message, and the run still offers Allow Once and Allow for This
  Run
- Remembering a folder that covers stored folders replaces them
- The Controllers & Permissions window lists each remembered folder under its policy, with the protected locations it
  lies in or names

## Decision Log

- 2026-11-15: Filed as a required prerequisite of UTERM-025. The user chose a folder granted at run time, with no
  `:fs-read`, over sending image bytes and over a scope fixed in the file.
- 2026-11-16: The deck is an argument, and uniterm hands the script its text. The user corrected the previous text,
  which had the deck arrive on stdin with the folder named separately. That text came from option wording the agent
  wrote. It left the deck and its folder unbound, so images could not load.
- 2026-11-16: Approval lifetimes follow UTERM-015. The user chose this over asking every run.
- 2026-11-16 (agent): the grant covers slide images only. A grant of UTERM-015's whole power would widen silently as
  other applets gain path commands.
- 2026-11-16: Review start: 1 milestone, 6 settled decisions, 5 risks, no `**Live after:**` lines or row gates; one
  out-of-scope statement, that the grant covers no path read but slide images. Proposal at the commit "Record a
  restored group's controller by its approval selector". The user asked for an autonomous review of the 5 open
  questions.
- 2026-11-16: Which argument is the input file: always the first argument after the script's file, checked against the
  snapshot's declaration. A missing one refuses the run in the command. Converged in 1 pass. (autonomous)
- 2026-11-16: How the text reaches the script: the command opens the file once with the invoker's access, after the
  snapshot's parse and before it sends the declaration, and hands the text to the script through a binding. The
  folder crosses beside the declaration report. Converged in 1 pass. (autonomous)
- 2026-11-16: How the script names the base folder: the command gives the script the canonical input path through a
  binding, and UTERM-030's base folder argument stays. Converged in 1 pass. (autonomous)
- 2026-11-16: Amended "The deck is an argument". Its bullet said "The script reads the path from its arguments, so it
  knows the folder it may pass to the viewer." A relative argument has no folder part, so the script now learns the
  canonical path from uniterm. (autonomous)
- 2026-11-16: Routed six checks to M1 from the first critique: the snapshot decides the mark, a leading `-` is refused,
  no controlling terminal, the canonical folder for linked decks, a size cap, and nil bindings. Routed three checks to
  UTERM-030 M2: a walk confined to the folder, protected locations inside the grant, and a base folder compared
  without touching the filesystem. (autonomous)
- 2026-11-16: The stored approval: a stored-only permission kind inside the run's request, with any policy that holds a
  folder in a third store older builds never read. The judge ruled after three passes without convergence (budget).
  The critic's top moved from a timestamp-bound folder file, to a `folders` field on the policy, to the third store,
  each on a confirmed objection: a revoked folder could return, and a folder outside the request let a run skip the
  sheet. (autonomous, judge)
- 2026-11-16: Amended "Version skew". Its third bullet said "A remembered approval of such a file makes an older build
  treat the whole policy file as newer, so every remembered approval goes inert until the user is back on the new
  build. That fails closed, as in UTERM-024 'Version skew'." It now keeps an older build's other approvals working. Dev
  and release builds share one store folder, so the replaced risk "Downgrading leaves every remembered approval inert",
  rated low and accepted, rested on a false premise. It is replaced by a high-likelihood, low-impact risk. The bullet
  was drafted by the agent, but the user has not reviewed the change. (autonomous, judge)
- 2026-11-16: Routed seven checks to M1 from the stored-approval passes: Allow once keeps the folder, revoke stops
  image loads, a restored pane holds no grant, a stray folder scope grants nothing, remember only when writable, case
  variants, and an older build's trust beside a newer one. (autonomous)
- 2026-11-16: Fixed a bug the critic found: the trust store could write a policy file larger than its reader accepts.
  The commit "Refuse a policy write the reader would refuse as too large" has the fix. Filed the bug
  `20261116-script-snapshot-reads-program-chosen-path`. (autonomous)
- 2026-11-16: Names: a declarable `input-file` kind that the app replaces with the stored folder kind, a per-meaning
  rule for where each kind may appear, `uniterm/input-text`, `uniterm/input-path`, and `uniterm/input-folder`, and a
  sheet line built from the folder alone. Converged in 1 pass. The critic proposed the third function and the sheet
  wording. (autonomous, addition: each permission meaning names where its kind may appear, which changes the reader
  shared with `controller.json`)
- 2026-11-16: Routed three checks to M1 from the Names pass: the lint counts the input functions, non-UTF-8 input is
  refused, and the sheet line is stable and escaped. (autonomous)
- 2026-11-16: Coherence review, full pass. Fixed in the text: "Approval lifetimes" named a session lifetime a declared
  file is not offered, and M1's Allow once check needed an exception the decisions never stated. M1 claimed image
  checks that UTERM-030 M2 builds later. The Impacts lines on UTERM-015 and UTERM-025 described the old stored
  approval. Split M1 into a run-only grant and M2 for remembered folders, both after UTERM-015 M4. Added three risks.
  (autonomous)
- 2026-11-16: Amended "Approval lifetimes". It said "the user chooses Allow once, for the session, or remember, as for
  UTERM-015's other path grants." It now names UTERM-021's choices, and Allow Once keeps the folder standing for the
  run beside Janet capabilities, since an image load has no question of its own. (autonomous)
- 2026-11-16: Amended "Names" to drop `uniterm/input-path`. It said the functions "return the text, the canonical
  path, and the folder the grant holds. Each returns nil in a run with no input file." No caller needs the path, and
  "Calls without an input file" replaces the nil. (autonomous)
- 2026-11-16: Amended "The stored approval". It said "The kind's meaning version goes up on any change to UTERM-015's
  protected-location list. After the list grows, the new meaning covers the old versions." Coverage reads the approved
  version's covers list, so the growth rule never applied. A raised version would also make a sibling build read the
  whole third store as newer. Each folder now records the protected-location names its sheet excluded. Converged in 1
  pass. (autonomous, addition: UTERM-015 M4's list gives each entry a stable name, and a narrowed entry a new one)
- 2026-11-16: What a denial covers: the version on that exact folder, with coverage checked first. A denial by version
  alone let a program turn off the user's remembered trust. Converged in 1 pass. (autonomous)
- 2026-11-16: Calls without an input file: the input functions raise in every run without one, with a message for each
  kind of run. Converged in 1 pass. (autonomous)
- 2026-11-16: Amended "How the script names the base folder" and "The deck is an argument" with the drop of
  `uniterm/input-path`: the script gets the granted folder, not the canonical path. (autonomous)
- 2026-11-16: Coherence re-check, pass 2: not converged. A widened protected-location entry kept its name, so an
  older build could cover a folder the sheet excluded. Any change of an entry's extent now takes a new name, and M2,
  not UTERM-015 M4, adds the names. Limited the coverage-before-denial order to runs with an input folder, since the
  general order would let a later identity trust admit a denied version. Routed five checks to M1 and M2. (autonomous,
  addition: M2 gives each entry of UTERM-015's protected-location list a stable name pinned to its extent, renamed on
  any change)
- 2026-11-16: Coherence re-check, pass 3: converged. Routed four checks: "only" holds until M2, the denial is a startup
  denial, the Ask Again row is escaped, and a policy removed during admission still meets the denial check. (autonomous)
- 2026-11-16: Risk review: every risk carries a likelihood, an impact, and a mitigation or an acceptance. None is high
  likelihood and high impact. The `input-file` contract and the third store are the one-way doors, and each is listed.
  The accepted risk is a revoke on an older build, rated low and medium. (autonomous)
- 2026-11-16: Review gate: kept all. The user kept the third store over files.json and a field on the record, which
  confirms the amended "Version skew" bullet and the replaced downgrade risk. The user also kept Allow Once granting the
  folder for the run, the per-meaning placement rule, and stable names on UTERM-015's list.
- 2026-11-16: ADR candidate (departs from the past): a remembered approval may hold a value a run supplied only when
  the sheet showed it. Declined: the user chose no ADR.
- 2026-11-16: ADR candidate (cuts across the system): a newer build's stored approvals never make an older build's
  existing approvals unusable. Waits on UTERM-024's design review, whose settled "Version skew" accepts the opposite
  for its new permission kind.
- 2026-11-16: Accepted after the review gate. No ADR written. UTERM-004 and UTERM-021 carry "Superseded in part by
  UTERM-032" markers.
- 2026-11-26: Amended for UTERM-067 "One store holds every approval": a folder policy lives in `policy.json` with every
  other approval, and the third store is never built. "The stored approval" said before: "A remembered policy that holds
  one lives in a third store beside `policy.json` and `files.json`. Older builds never read that store." Its bullets
  said: "A file policy that holds a folder lives whole in the third store, under the same selectors, strict reader, and
  lock discipline as `files.json`. Each selector lives in one store. A revoke removes the selector from both stores,
  taking the locks in a fixed order. A move between stores writes the new store first, so a crash leaves a duplicate,
  never a loss. A selector found in both stores grants the union, since the user approved each." and "A revoke on an
  older build reaches only `files.json`. The folder policy stays until it is revoked on a build that reads the third
  store." The cap bullet's byte limit and "revoke some first" message gave way to UTERM-067's bound. Its rationale's
  reason for a separate store, the matching "Version skew" bullet, the Impacts line on UTERM-021, two risks, the M1
  check naming both files, and the M2 checks on two stores changed to match. Removed the risk "A revoke on an older
  build does not reach the third store", which needs a third store. uniterm is pre-v1, and UTERM-067's reader keeps an
  entry it cannot read, so a store of its own is not needed.
- 2026-11-17: Amended by UTERM-029, which adds PDF and image-folder decks. "The grant covers slide images only" now
  counts a PDF page as a slide image. "How the text reaches the script" admits a PDF or a folder under `input-file`
  version 2, and its UTF-8 check and size cap apply to text only. "Calls without an input file" said the error "names
  `{:kind :input-file :version 1}`", and now names the version the call needs. "Names" said "No function returns the
  file's own path, since no caller needs it", and the sheet line said "Let the text viewer show images from
  /Users/me/talks/demo or a folder inside it, in panes it controls". `input-name` now returns the base name, and the
  sheet line names PDF pages. The stored folder kind keeps its version, so an older build still reads the store.
- 2026-11-21: Scheduled as UTERM-032 M1-M2 in queue.md.
- 2026-11-22: UTERM-034 was accepted. It removes the declared-file snapshot that "Which argument is the input file" and
  "How the text reaches the script" name. This proposal is queued first, so its text stays as written. UTERM-034 M1
  amends both sections and the M1 check on a file that gains the mark before the snapshot, when it lands.
- 2026-11-23: From UTERM-056's acceptance. "Version skew" said a mismatch "fails at the hello before any effect".
- 2026-11-27: From UTERM-063. ScriptWire is at 0 and does not bump, and a declarable kind carries no version, so the
  `input-file` kind is named alone and has an internal edition. The new messages land in place after UTERM-063 M2.
  - Amended "Version skew". It said "so ScriptWire's version goes up", and that a mismatch "fails at the hello, or, for
    an old command once UTERM-056 has landed, at its begin".
  - Amended "How the text reaches the script", "Calls without an input file", and "The declaration and the host
    functions". They said `input-file` version 2 takes PDF and folder inputs, that the error names "version 1 for
    `input-text` and `input-folder`, version 2 for UTERM-029's functions", and that a file declares
    `{:kind :input-file :version 1}`.
  - Amended "The stored approval". It said "The kind's meaning version never changes with the list", and that "A
    meaning version raised with the list would make a build that lacks the newest version keep every folder policy
    unread".

## References

- ADR-03: restored state never runs a program
- ADR-09: control authority requires authenticated identity and explicit scope
- ADR-10: helper sandboxing
