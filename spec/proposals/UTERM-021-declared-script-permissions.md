# UTERM-021: Declared Permissions for Script Files

**Status:** implemented
**Created:** 2026-11-13
**Updated:** 2026-11-23

## Dependencies

- UTERM-003, for `uniterm run`, the Janet sandbox, and the REPL
- UTERM-004, for controller packages, the review, remembered trust, and the call-boundary check

## Impacts

- UTERM-004 — "Permission scopes and approval flow" and "Controller trust and approval choices": the review's
  per-run choice is named "Allow for This Run", and plain-script questions use the same name. A declared file takes
  the review and trust choices a controller takes.
- UTERM-004 — "Verified artifact and run binding": a single file becomes a second verified artifact beside the
  package, with its own snapshot and version.
- UTERM-003 — "Where scripts run": the app reads and snapshots a declared script file before the command runs it. The
  command runs the snapshot, not the bytes it read itself. An undeclared file is not snapshotted, and its run waits
  for the app's answer. `uniterm run` no longer sends the plain begin.
- UTERM-003 — the command's public exit statuses (64, 66, 69, 70): a refusal from the app, such as strict mode, a
  rejected review, or a denial, exits 77. 69 stays for no uniterm reachable, so a caller that retries on 69 does not
  retry a refusal. See Decision Log.

## Summary

A single Janet file states the powers it needs in a first `(declare-permissions ...)` form. uniterm reads that form as
data, snapshots the file, and runs the copy. The review shows the declared powers before any code runs, and a declared
file can be trusted by version or, when signed, by identity. A call outside the declaration is refused. By default
uniterm runs in strict mode, which refuses a file that declares nothing. An unsafe mode lets the user run such a file
for one run. A lint command compares a file's calls with its declaration.

## Motivation

A controller package declares its powers in `controller.json`. uniterm shows them in the review and refuses anything
undeclared. A plain `uniterm run file.janet` has none of that. Nothing is reviewed at start, nothing can be trusted
across runs, and each clipboard use asks on its own. A user cannot tell ahead of time what a plain script will do.

Making every script a package is heavy for a one-file tool. A descriptor, a file list with digests, and a folder are a
lot to ask of a ten-line script. The file can carry its own declaration instead. Enforcement at the call boundary
already fails closed, so the declaration only has to say what to review. It need not prove what the code will call.

The review wording also disagrees with itself. The startup review says "Allow for This Session", and a question row
says "Allow for This Run" or "Allow for This Connection". All three mean one run.

## Design Decisions (Settled)

### The declaration form

Decision: a file declares its powers with `(declare-permissions ...)`, its first form.

```janet
#!/usr/bin/env -S uniterm run
(declare-permissions {:id "dev.example.tidy" :name "Tidy"}
  {:kind :pane-control :version 1}
  {:kind :clipboard-read :version 1})

(import uniterm)
```

- Only a `#!` line, comments, and whitespace may come before it. A declaration anywhere else is an error. A comment
  cannot hide code, since the parser skips it.
- It appears exactly once. A second declaration is an error.
- It holds literal data only: keywords, strings, numbers, tuples, and structs. A symbol, a call, a quasiquote, or an
  unquote refuses the file.
- The permissions use `controller.json`'s (kind, version) vocabulary and its rules. An unknown kind or version
  refuses the file, and so does one kind listed twice. A scoped kind, such as a capability or a host launch, is
  listed once for each scope: a capability by its name, and a host launch by its executable alone. Amended
  2026-11-15; see Decision Log.
- An optional leading struct carries `:id` and `:name`. The ID follows `controller.json`'s ID rules. It is required
  when the file is signed. An unsigned file without a name is shown by its file name.
- uniterm binds `declare-permissions` before the file loads, so a misspelled form fails as an unbound symbol. At run
  time the form expands to nothing.
- The name sits outside the `uniterm/` namespace. A declaration is not a call, and should not read like one.

Rationale: a dedicated form makes a typo fail loudly. A `def` with a well-known name would read as no declaration, and
the file would run as an undeclared script. Literal data can be read without running anything. A form at a fixed
place cannot hide behind code that runs first.

### Authority comes from the read, not the run

Superseded in part by UTERM-034; see Decision Log.

Decision: uniterm reads the declaration with Janet's own parser, from the snapshot's bytes, before any of the file
runs. The value the form has at run time grants nothing. "Where the declaration is read" says which process runs the
parser.

Rationale: a separate hand-written reader could read a crafted file differently from how the VM reads it. Reading
with the parser that will run the file closes that gap.

### The file is snapshotted and hashed

Superseded in part by UTERM-034; see Decision Log.

Decision: the app reads the file, copies it to a private read-only snapshot, and the command runs that copy. The
version is the SHA-256 of the whole file, declaration included.

- A declared file runs alone. Its loader resolves only uniterm's bundled modules, as a package's does, and no file. A
  script that needs other files must be a package.
- `--allow` names only capabilities the file declares, as it does for a package.

Rationale: an approval must bind to the bytes that were reviewed. Otherwise the file could change between the review
and the run.

### Signing

Decision: a file is signed by a detached `file.janet.sig` beside it. The signature uses `controller.sig`'s scheme, an
Ed25519 signature over a fixed domain line and the file's exact bytes. A signed file's leading struct must carry an
`:id`.

- The domain line is `uniterm script file 1`, where a package descriptor's is `uniterm controller descriptor 1`, so a
  signature for one never verifies the other. Amended 2026-11-15; see Decision Log.
- A signature that does not verify refuses the file. It never falls back to an unsigned version.
- Identity trust pins the public key plus the ID, as it does for a controller.

Rationale: a signature cannot sit inside the bytes it covers. An embedded signature would need byte-exact exclusion
rules, which are easy to get subtly wrong. A sidecar keeps one verifier for packages and files.

### Undeclared powers are refused

Decision: a call from a declared file or a controller that needs a power it did not declare is refused. The error names the
undeclared permission. uniterm never offers to allow it.

Rationale: strict enforcement is the point of declaring. An offer to allow extra would turn every declaration into a
starting bid.

### Strict and unsafe modes

Decision: a uniterm setting chooses strict or unsafe mode. Strict is the default. A run cannot choose its own mode,
and `uniterm run` takes no flag for it.

| File | Strict | Unsafe |
|---|---|---|
| Declares its powers | Review with Deny, Allow Once, Allow for This Run, Trust This Version, and Trust This Identity when signed | Same |
| Declares nothing | Refused | Review with Reject, Allow and Ask Each Use, Allow Everything |

- Strict mode's refusal says uniterm is in strict mode and names `(declare-permissions ...)`.
- Each unsafe choice lasts one run. An undeclared file has no trust choice. Its review says that adding a declaration
  makes the script trustable.
- Once the run starts, Allow and Ask Each Use keeps the call behavior plain scripts have today. Clipboard calls ask.
  Pane calls follow the pane rules. The review before the run is new, so an undeclared file in unsafe mode asks once
  per run where today it asks nothing at start.
- Allow Everything grants clipboard read and clipboard write for the run. Pane calls follow the pane rules under both
  choices, so the clipboard is the only difference. The review lists the two powers and any `--allow` capabilities.
  The grants stay revocable from the Pending Requests panel and are checked at the call boundary like any grant. A
  host launch has no blanket scope, so it still asks on each use.
- Strict mode is a policy for the `uniterm` command, not a boundary against other programs. A generic peer that is not
  the bundled command keeps the admission UTERM-004 gives it. The app tells the two apart by authenticating the peer,
  as it does for packages. ADR-09 already places other processes of the same user outside what uniterm defends
  against.
- An undeclared file is not snapshotted. The command reads and runs it, so `uniterm run <(...)` still works in unsafe
  mode. The command does not start it until the app answers. It sends an undeclared begin naming the file and the
  `--allow` capabilities, and waits for admitted, refused, or reviewing, as a package run waits. A generic peer's plain
  begin stays as UTERM-004 has it, with no answer.

Rationale: a declared file can be reviewed, trusted, and enforced. An undeclared file can only be guessed at, so the
default refuses it. The setting belongs to whoever owns uniterm. A flag would let whoever types the command, or a
script that runs `uniterm run` on another file, pick the mode. Remembered trust records (kind, version, scopes), and an
undeclared file has none to record.

### Run wording

Decision: every choice that lasts one run is named "Allow for This Run". That covers the startup review, controller
questions, and plain-script questions, which said "Allow for This Connection". A REPL pane's questions and a generic
peer's keep "Allow for This Connection", since neither connection is a run.

Rationale: a plain script's connection is its run. Three names for one lifetime confused the user in hands-on review.

### The lint

Decision: uniterm ships a lint that scans a file's literal `uniterm/` calls and compares them with its declaration.
It reports calls that need an undeclared power, and declared powers the file never uses. It is best effort and
grants nothing. A dynamic call, such as one built with `symbol` or run through `eval`, makes it report that the file
could make any call, and then it reports no declared power as unused. "The lint's name" says how it is invoked. Its
exit status is 0 when clean, 1 with findings, 65 when the file or its declaration does not read, and 66 when the file
cannot be opened. Amended 2026-11-15; see Decision Log.

Rationale: enforcement makes a missed call safe. It is refused at run time. A lint moves that error to before the run.

### Where the declaration is read

Superseded in part by UTERM-034; see Decision Log.

Original question: the app does not link Janet, and ADR-07 keeps Janet out of it. Which process parses the
declaration: a new sandboxed parse helper, the authenticated command, or a Swift reader in the app?

Decision: the authenticated command parses the snapshot and reports the declaration to the app.

- The command reads the file. When its first form is a declaration, the command resolves the file's path and sends a
  file begin. Otherwise it sends an undeclared begin, which strict mode refuses before any code runs. What the command read only routes the
  run. The snapshot's parse decides what is declared. The app reads the file and refuses anything but a
  regular file within a size cap. It hashes and snapshots the file and verifies any `.sig`. It answers with the
  snapshot and the version.
- The command checks the snapshot's hash, then parses its first form with the Janet it will run. It converts the
  declaration to `controller.json`'s permission structure and sends it.
- The app validates the declaration with the strict permission reader packages use, looks up trust by the version,
  and reviews or admits the run.
- A parser exploit inside the declaration runs in the unsandboxed command before the review. That is no worse than
  the whole-file parse after approval, which no option can sandbox, since ADR-10 keeps the command outside the App
  Sandbox.

Rationale: the same parser reads the same bytes, so no differential is possible. The app already trusts the
authenticated command to apply the Janet sandbox and to run the snapshot it was given. A sandboxed parse helper
protects only a parse the attacker can route around, by putting the exploit in the second form, and it adds a helper,
a wire protocol, and entitlements. A Swift reader would be a second Janet grammar to keep in step with every Janet
release, and its run-time cross-check never fires when the two readers disagree about where the first form starts.
Linking Janet into the app breaks ADR-07 and `scripts/check-janet-isolation.sh`.

### One run per command process

Decision: the app accepts one session per command process. A begin from a process that already has a run admitted,
waiting, or refused, or a REPL attached, is refused, whether it begins a plain file, a declared file, or a package.

- A native entry is the exception. Once `uniterm controller run` execs it, the whole process is the controller, so
  every connection of that exec generation is adopted as today.

Rationale: the command opens its session before any script code runs, so a later begin from that process comes from
script code. A script granted a way to reach the socket, such as `net-connect`, could otherwise begin a trusted file
or package on a second connection, and run its own code under that run's standing powers. With the command reporting
the declaration, it could also put a forged declaration in front of the user under another file's verified identity.
The rule covers packages as well as files, since the same second connection could begin a trusted package. It
covers a REPL helper too, since code typed or pasted into a REPL granted `net-connect` could do the same.

### The declaration's data shape

Original question: should kinds be keywords or strings, how are host-launch fields spelled, and does the declaration
carry a format number?

Decision: field names are spelled as `controller.json`'s keys. Closed sets are keywords, and free text is strings.

```janet
(declare-permissions {:id "dev.example.tidy" :name "Tidy"}
  {:kind :pane-control :version 1}
  {:kind :capability :version 1 :name :fs-read}
  {:kind :host-launch :version 1 :executable "/usr/bin/git" :directory "/Users/me/src"
   :environment ["HOME" "PATH"]})
```

- Kinds and capability names are keywords. Janet's own `sandbox` spells capabilities as keywords.
- The ID, the name, paths, and environment keys are strings. Versions are whole numbers.
- The header is the leading struct without a `:kind`.
- There is no format number. An unknown field or kind refuses the file, so an older build fails closed on a newer
  declaration. A later change to the header adds a `:format` key, whose absence means today's shape.
- A proposal that adds a permission kind also defines its declaration spelling: which fields are keywords and which
  are strings.

Rationale: keywords are how Janet spells a closed set. The conversion to `controller.json` keeps each spelling, so it
is a mechanical step. A required format number would make the optional header required, and it guards against no
failure that refusing unknown fields does not already catch.

### Trust records for files

Superseded in part by UTERM-032; see Decision Log.

Superseded in part by UTERM-067; see Decision Log.

Decision: file approvals live in their own policy file, beside the controller policy file, with their own selectors.

- A file's version selector names the file's SHA-256 alone, so an unsigned file needs no ID.
- A file's identity selector names the ID and the key fingerprint. It never matches a package, and a package's never
  matches a file, even with the same ID and key.
- The file uses the controller policy file's strict reader, its newer-format rule, and its own record limit.

Rationale: the controller policy reader moves aside a file whose selector kind it does not know. Writing file records
into it would make an older build, on downgrade or running beside a newer one, move it aside and lose every controller
approval. A separate file leaves an older build's controller trust working and its file trust simply absent. Separate
selectors keep a signed file from running under a package's identity approval. Every edit of a file is a new version,
so a separate limit also keeps file approvals from crowding out controller approvals.

### Capabilities that load native code

Decision: a declared file cannot declare `ffi`, `ffi-define`, `ffi-jit`, `ffi-use`, or `modules`, the same as a package.
A script that needs one runs only as an undeclared file in unsafe mode, with `--allow` as today.

Rationale: native code loaded at run time escapes the snapshot an approval binds to. Strict mode therefore has no way
to run such a script, and says so in its refusal.

### The lint's name

Original question: is the lint `uniterm lint file.janet`, or `uniterm run --check file.janet`?

Decision: `uniterm lint file.janet`, a command of its own beside `run`. It parses and scans, runs none of the file's
code, and never contacts the app.

Rationale: everything after the script's path in `uniterm run` belongs to the script. A misplaced `--check` would then
run the code it was meant to lint, and a shebang run passes it the same way. Putting the lint under `uniterm
controller` would group it with signing and keys, which are about who wrote a file, not what it calls. Covering
packages is out of scope.

### Where the mode setting lives

Original question: which Settings page shows strict and unsafe, and does a change affect runs already waiting?

Decision: a choice row on the Settings page, "Script files", with Strict and Unsafe. A missing or unknown stored value
reads as strict.

- Switching to strict refuses every waiting undeclared-file review, with a message naming strict mode. An admission or
  an answer that finishes after the switch is refused too.
- A live undeclared run keeps running after a switch to strict. The user ends its authority with Revoke, as for a
  controller run. Its next call is refused, and the process is not stopped. Amended 2026-11-15; see Decision Log.
- Switching to unsafe affects runs that start afterward.
- Strict mode's refusal names the Settings row.

Rationale: settings live on the Settings page, and the refusal can point there. An undeclared file never has a
remembered approval, so the Controllers & Permissions window would put the row beside nothing it governs. A switch to
strict that left a waiting review answerable would let the user grant Allow Everything against the policy they just
chose. The code already takes that stance: a trust removal during admission sends the run to review. A same-user
process can change the stored value. ADR-09 already places other processes of the same user outside what uniterm
defends against, and unsafe mode still asks the user before anything runs.

### Out of scope

- REPL panes. Code typed into a REPL has no file to declare in. Its powers stay as UTERM-003 and UTERM-004 define.
- Packages. `controller.json` is unchanged, apart from the run wording.

### Version skew

Decision: the change follows UTERM-004's skew rules.

- The command and the app: declared files add a file begin and a declaration message, and undeclared files add an
  undeclared begin with an answer. ScriptWire's version goes up. Each side refuses any
  other version at the hello, so an older command and a newer app refuse each other before any effect.
  Superseded in part by UTERM-056; see Decision Log.
- The trust store: a file's version and identity approvals are new records in their own policy file. The controller
  policy file's format and records are unchanged.
- An older build running a declared file fails at load, since it has no `declare-permissions` binding. That fails
  closed.
- An older build never reads the file policy file, so its controller trust keeps working. A newer build reads an
  older one's controller policy file unchanged.
- An older build ignores the mode setting and runs undeclared files as it does today.

## Design Decisions (Open)

None.

## Risks

- **Strict mode by default refuses every existing plain script** — likelihood: high, impact: medium.
  Mitigation: the refusal says uniterm is in strict mode, names the form to add, and names the Settings row. The
  scripts that the UI tests run through the bundled command carry declarations or run in unsafe mode. The package
  tests' script fixtures stay undeclared. Unsafe mode runs an undeclared file after one review per run. A declaration
  plus Trust This Version removes the review until the file changes. No setting restores today's run with no
  review at all, which is the point of the change.
- **A parser differential lets the review show something other than what runs** — likelihood: low, impact: high.
  Mitigation: the declaration is read with Janet's own parser from the snapshot's bytes. Enforcement uses the approved
  scopes whatever the review showed, so a differential cannot grant an unapproved power.
- **Allow Everything is a blanket grant to code that said nothing** — likelihood: medium, impact: medium.
  Accepted: it exists only in unsafe mode, which the user turns on. It lasts one run, names its two powers, stays
  revocable, and never covers a host launch.
- **The declaration form becomes a published contract** — likelihood: high, impact: medium.
  Mitigation: each permission carries a version, and an unknown kind or version refuses the file. A newer build reads
  older declarations with their own meanings. A later header change adds a `:format` key, whose absence means
  today's shape.
- **The trust store gains new record types** — likelihood: high, impact: low.
  Mitigation: file records live in their own policy file, which an older build never reads. A downgrade loses file
  trust and keeps controller trust, so trust is lost instead of widened.
- **Strict mode does not stop a generic peer** — likelihood: medium, impact: low.
  Accepted: a same-user program that is not the bundled command keeps UTERM-004's admission, so it can run undeclared
  code against uniterm in strict mode. ADR-09 already places such programs outside what uniterm defends against.
  Strict mode keeps the user from running an undeclared file through `uniterm run` by accident, which is its purpose.
- **Permission kinds that other proposals add need a declaration spelling** — likelihood: high, impact: low.
  Mitigation: the data-shape decision requires each proposal that adds a kind to define its spelling. An unknown kind
  refuses the file, so a kind that lands without one cannot be declared, and nothing is granted by mistake.
- **A user who trusts every edit of a file piles up version records** — likelihood: medium, impact: low.
  Accepted: file approvals have their own limit, so they cannot crowd out controller approvals. Saving past the limit
  fails with a message, and Revoke clears old versions in the Controllers & Permissions window.

## Milestones

### M1: Run wording

**Status:** DONE

- The startup review, controller questions, and plain-script questions all name their per-run choice "Allow for This
  Run"
- The review's help text and the waiting-runs text use the same name
- A UI test screenshot of the review and of a question row shows the new name
- A REPL pane's questions and a generic peer's still say "Allow for This Connection"

**As built:**

The app now records what each connection is: a controller run, the bundled command running a plain script, a generic
peer, or a REPL pane. A plain begin is told from a generic peer on the main actor by comparing the running code's
dynamic signing information with the command's file, which is validated once off the main actor and kept. A native
controller's process skips the check. A missing controller setting leaves a plain begin a generic peer. The question
row reads the kind to pick between "Allow for This Run" and "Allow for This Connection". The controller approval line
now reads "Allowed for this run".

The strict and unsafe modes milestone later changed the check that tells the command from a generic peer. A peer the
cached comparison does not take for the command now gets the full check before it is admitted as a generic one. See its
As built.

### M2: Declared files

**Status:** DONE

Superseded in part by UTERM-034; see Decision Log.

- A file with a valid declaration shows a review listing its powers before any of its code runs
- A second declaration, a declaration after another form, a non-literal value, an unknown kind or version, and a
  repeated kind each refuse the file with a message naming the problem
- A misspelled form name fails as an unbound symbol
- The command runs the snapshot, and an edit to the file after review does not change what runs
- Trust This Version keeps the next run of the same bytes from asking, and an edited file gets a fresh review
- A call needing an undeclared power is refused, and the error names the permission, for files and controllers
- An older command and a newer app refuse each other at the hello
  Superseded in part by UTERM-056; see Decision Log.
- A file reached through a symlink runs, and a pipe, a device, or a file over the size cap is refused
- The command refuses a snapshot whose hash differs from the version the app sent, before parsing it
- A duplicate key in a struct, `nil`, `true`, `false`, a parenthesized tuple, and a fractional version each refuse the
  file, although Janet's parser would merge or drop them. The check reads the same parser's state before each struct
  closes, and can only refuse
- An empty declaration, `(declare-permissions {:name "x"})`, runs with no powers beyond posting status
- The command runs the bytes it hashed, not a second read of the snapshot, and `(dyn :args)` starts with the original
  path
- A call before admission is refused, as for a controller
- A file begin whose declaration never arrives is refused after a bound
- A first form that is a near miss of the declaration is refused with a message that the declaration must come first
- A signed file and a package with the same ID and key do not share an identity approval
- An older build opening a policy folder that holds file approvals keeps its controller approvals
- A permission whose misspelled `:kind` reads as the header is refused with a message naming the likely typo
- A declared file that declares `ffi`, `ffi-define`, `ffi-jit`, `ffi-use`, or `modules` is refused
- A second begin from a process that already has a run or a REPL attached is refused, for files and for packages. A
  generic peer that already has a plain session can still open another, as UTERM-004 allows
- A peer that is not the bundled command and sends a file begin is refused before any snapshot is made
- A file begin whose snapshot's first form is not a declaration is refused, not run as undeclared
- `(import ./x)` from a declared file finds nothing
- File approvals appear in the Controllers & Permissions window, and Revoke removes them
- The file policy file's kept-aside copies and temporary files are named apart from the controller policy file's
  `policy.aside-*.json` and `policy.json.tmp-*`, so neither store prunes or sweeps the other's
- Every connection a native entry opens after `uniterm controller run` execs it is still admitted

**As built:**

A script file with a valid first-form declaration now runs end to end. The command parses the file's first form
with Janet's own parser, in a VM of its own that evaluates nothing, and sends a file begin that names the resolved
path. The app authenticates the command, and only then opens the path without following a link. It requires a regular
file within a size cap, copies it into the run's private folder while hashing it, checks the copy, and makes it
read-only. It answers with the copy's path and the file's SHA-256. The command reads the copy once, checks the hash
before it parses, reads the declaration from those bytes, and reports it as JSON in the permission structure
`controller.json` uses. The app reads that JSON again with the strict reader that packages use, looks up trust by the
version, and admits the run or queues the review. Only then does the command run the bytes it hashed, with a module
loader that finds nothing but the bundled `uniterm` module. `declare-permissions` is bound as a macro that expands to
nil in every run, so a misspelled form fails as an unbound symbol.

The size cap is a packaged file's, 32 MiB. The declaration message is capped at 32 KiB of JSON. ScriptWire is at
version 10, which adds the file begin, the file-admitted answer, and the declaration message. The final admission
reuses the controller admitted answer.

The check for what Janet's parser would merge or drop reads the parser's state before each `}`. It ends a token still
open with a space first, so the state shows every value. It mirrors three parser-private flag bits of the pinned Janet
release, and the duplicate-key and nil tests fail if an upgrade moves them. It applies only to the first form, and
only when that form is the declaration, so a plain script's own structs are never refused. A later declaration is a
parenthesized form whose head is the symbol `declare-permissions`, found at any depth outside a quote or a quasiquote.
A bracketed list that starts with the name, quoted data, and a docstring are data, so an undeclared script may mention
the name. The reader stops walking forms past 512 levels of nesting. A file that does not parse reads as undeclared,
and the run reports the parse error.

A struct with no `:kind` that holds a key within two edits of `kind`, of three letters or more, is marked in the JSON
by the command's reader. That reader alone judges what looks misspelled. The Swift reader only words the message from
the mark.

The shared permission reader moved out of the descriptor reader into its own type. A file declaration and a
descriptor read the same list through it, and only the wording of the native-code refusal differs.

An undeclared file still sent the plain begin at this milestone. The strict and unsafe modes milestone later replaced
that with the undeclared begin. See its As built.

File approvals live in their own `files.json`, beside `policy.json`, with their own lock, `files.aside-N.json` copies,
`files.json.tmp-*` sweep, and 256-record limit. Both selectors exist now: the file version, which names only the
SHA-256, and the file identity, which names an ID and a key fingerprint. Nothing creates an identity approval yet,
since an unsigned file has no key. A policy file of one kind that holds a selector of the other is unreadable, so
neither store can be read as the other. An unsigned file with no declared name is titled by its file name in the
review, cleaned as a descriptor name is, and a file name that cannot pass that is shown as "script file". The window
lists an unsigned file's approval as "script file" too.

The app keeps one table of command processes, keyed by process ID, start time, and process ID version. A plain begin
from the bundled command, a controller begin, a file begin, and a REPL attach with a token the app issued each claim an
entry first, and a second claim is refused. A bad token gets the attach's own refusal and costs the process nothing. A
controller or file begin claims only when the cheap check on the main actor says the peer is the bundled command, and
before the admission starts. A second begin from the command is therefore refused while the first still authenticates,
and a program that is not the command takes no place, so it cannot fill the table. The strict and unsafe modes
milestone later changed two of these rules. The app now refuses a plain begin from the bundled command instead of
claiming an entry for it, and a begin the cached check did not take for the command claims its entry when the full
check passes. See its As built. The table outlives the connection.
At 1024 entries it drops those whose process has exited, and past that it refuses a new begin. A generic peer's plain
begins are not counted, and a native entry's connections are generic peers, so every connection one opens after the
exec is still adopted.

The app refuses any path under `/dev`. The command resolves a path and the app opens it, so `/dev/fd/N` would name the
app's own descriptor and copy whatever file the app holds open. A file name that is too long for a review title keeps
its start and its extension, with an ellipsis between, so the cut shows. A name that cannot pass the descriptor name
rules is shown as "script file".

`uniterm run` on a pipe fails in the command's own read, as it did before, so the app's refusal of a pipe, a device,
and an oversize file is proved against raw peers and the snapshot itself.

### M3: Signed files

**Status:** DONE

Superseded in part by UTERM-034; see Decision Log.

- `uniterm controller sign` signs a file and writes `file.janet.sig`
- A signed file offers Trust This Identity, and a new version under a trusted identity that asks for nothing new runs
  without review
- A signature that does not verify refuses the file
- A signed file without an `:id` is refused
- The file signature's domain line differs from the controller descriptor's, so a package signature never verifies a
  file
- A valid `.sig` beside an undeclared file grants no identity

**As built:**

`uniterm controller sign --key NAME file.janet` signs a script file. The path is a package when it is a
folder and a file otherwise. The command resolves the file's path, because the app reads the `.sig` beside the
resolved path. It refuses a file whose first form is not a declaration, a declaration that fails to read, and a
declaration with no `:id`. It writes `file.janet.sig` atomically in `controller.sig`'s format and prints the ID,
the version, the key's fingerprint, and the path it wrote.

The signature type now takes a subject. A descriptor's domain line is still `uniterm controller descriptor 1`,
and a script file's is `uniterm script file 1`. Verifying and signing take the subject, and the descriptor forms
call them with the descriptor subject. A file signature that fails raises its own error case, so the message
names the file's `.sig` and not `controller.sig`.

The app reads the `.sig` while it snapshots the file. It looks beside the resolved path, refuses a link, a pipe,
and a device, and caps the signature at 4 KiB. It verifies over the bytes it read back from the copy, which are
the bytes it hashed. A `.sig` that is there and does not read or verify refuses the file and removes the copy.
The snapshot carries the verified signature. The file's identity takes the signature's key fingerprint. A signed
file whose header names no `:id` is refused after the command reports the declaration, with a message that asks
for one. Nothing on the plain path reads a `.sig`, so a valid or broken signature beside an undeclared file
changes nothing about its run.

Trust This Identity was already offered for any review whose identity carries a fingerprint, so a signed file now
gets it. It writes a file identity approval of the ID and the key. A later version under that approval that asks
for no new power runs without a review. One that asks for more gets a review that lists what is new. A package
identity approval with the same ID and key does not cover the file, and the review's help text says "file ID" for a
file.

### M4: Strict and unsafe modes

**Status:** DONE

- The setting defaults to strict
- In strict mode, a file without a declaration is refused with a message naming strict mode and the form
- In unsafe mode, such a file shows Reject, Allow and Ask Each Use, and Allow Everything, and none offers trust
- The unsafe review lists the run's `--allow` capabilities
- A generic peer that is not the bundled command keeps UTERM-004's admission in strict mode
- An undeclared file runs none of its code, with or without `--allow`, until the app admits it; strict mode refuses it
  before its first form runs
- In unsafe mode, an undeclared file with a later `(declare-permissions ...)` form is refused before any of its code
  runs
- The app refuses a plain begin from a peer it authenticates as the bundled command
- A request on an undeclared-begin connection before admission is refused
- Allow Everything lets clipboard calls run without asking for that run, and a host launch still asks
- Revoking an Allow Everything grant refuses the run's next call
- Switching to strict refuses every waiting undeclared-file review with a message naming strict mode
- An admission in flight, or a review answer, that finishes after a switch to strict is refused
- A live undeclared run keeps running after a switch to strict, and Revoke ends its authority, so its next call is
  refused
- A missing or unknown stored mode reads as strict
- The scripts that the UI tests run through the bundled command carry declarations, or run in unsafe mode when the test
  is about an undeclared file, and the package and UI test suites pass in strict mode. The package tests' script
  fixtures stay undeclared, since the SwiftPM test helper that runs them is a generic peer, and a declared file needs
  the bundled command. Amended 2026-11-15 in two bullets; see Decision Log.

**As built:**

The Settings page has a "Script files" row with Strict and Unsafe, and a missing or unknown stored value reads as
strict. The host reads the store each time it needs the mode, and watches the key. ScriptWire is at version 11, which
adds the undeclared begin and its admitted answer. Refusals and the review notice reuse the controller answers. The
command opens a session for an undeclared file with the undeclared begin and runs none of its code until the app
admits it. It no longer sends the plain begin.

The app tells the bundled command from any other program with the cheap check it already runs on the main actor, and the
full check follows off the main actor. A plain begin from the command is refused and its connection closed. An
undeclared begin from the command claims its place in the one-session table, then takes one of two paths. Strict mode
refuses it with a message that names the mode, the form to add, ffi and modules, and the Settings row. Unsafe mode puts
a review in the Pending Requests panel once the full check passes, and the mode is read again when the check finishes. A
call from the connection before the answer is refused, as for a controller. Every refusal of a begin marks the
connection refused as it is sent, so a request already on the wire is dropped without waiting for the close. An
undeclared begin from a program that is not the command gets the admission a plain begin gets, with an admitted answer
at once and no review, so the SwiftPM test helper and any other program that speaks the wire are unchanged in strict
mode.

The review offers Reject, Allow and Ask Each Use, and Allow Everything. It lists the run's `--allow` capabilities and
says a declaration makes the script trustable. No choice is remembered, and none is a trust choice. Ask Each Use leaves
the connection as a plain script's is, with clipboard questions and the pane rules. Allow Everything puts the clipboard
read and write in the connection's standing clipboard grants, which the call boundary already checks, so a host launch
still asks. The Pending Requests panel lists every live undeclared run, not only those with Allow Everything. Revoke on
a row does what Revoke does for a controller run or a declared file run: it ends the run's authority, so its next call
is refused, and it does not close the connection or stop the process. Switching to strict refuses each waiting review at
once. An answer that arrives after the switch reads the mode again and refuses the run, and an admission in flight is
refused when its full check finishes. A live run is left alone. A file with a later `(declare-permissions ...)` form is
refused by the command before it connects, as the M2 reader reports it, so the app never sees that begin.

A peer that the cheap check does not take for the command gets the full check, off the main actor, before it is
admitted as a generic one. A command replaced on disk under a running app fails the cheap check, and would otherwise
have been admitted with no review. The connection's calls wait for the decision. The check refreshes the cached copy of
the command's signature when it passes. A file or controller begin that the cheap check did not take for the command
claims its place in the one-session table when its full check passes. The window's pending slot counts an undeclared
review as it counts any other row.

An app refusal of a run, whether strict mode, Reject, a switch to strict, a denial, or an undeclared power at
admission, makes the command exit with status 77. Status 69 stays for no reachable uniterm, so a caller that retries on
69 does not retry a refusal. A socket that belongs to another user is a failure to reach uniterm, not an answer from
it, so that failure keeps 69. Only a refusal that came from the app exits 77.

The package tests' script fixtures stay undeclared, and the tests that exercise a plain script through the real signed
command set unsafe mode and answer the review. The UI tests that drive the real app declare their scripts, answer the
review in the panel, and seed unsafe mode for the plain-script question and the unsafe review. The decision for the
fixtures is in the Decision Log.

### M5: The lint

**Status:** DONE

- The lint reports a literal call whose power the file does not declare
- The lint reports a declared power the file never uses
- A file that builds a call name or uses `eval` is reported as able to make any call
- The lint runs none of the file's code
- `(use uniterm)`, `(import uniterm :as u)`, an alias of a `uniterm/` function, and a macro defined in the file are
  each resolved or reported as able to make any call
- A declared capability is never reported as unused, since its uses are Janet's own functions
- The lint maps calls to powers with the same table the app uses at the call boundary

**As built:**

`uniterm lint file.janet` is a command beside `repl` and `controller`. It takes one file, and `-h` or `--help` shows
its usage. It refuses a folder, a second file, and any other flag with status 64. It reads the file, parses it, and
prints one finding per line as `file:line:column: text`. It opens no socket and reads no address, so it never contacts
the app. It runs none of the file's code.

The shim parses the file with Janet's parser in a VM of its own and copies the forms into plain arrays. The walker is
Swift. A tuple's position is the parser's own source map, so a reference is reported at the form that holds it. Exit
status is 0 when clean, 1 with findings, 65 when the file does not parse, nests past 512 levels, or has a declaration
that fails to read, and 66 when the file cannot be opened. A parse error names its line and column.

The call-to-power table moved into ScriptWire. `ScriptCallKind` lists each wire call with its Janet name and its power,
and `ScriptCall.kind` is an exhaustive switch over the wire calls. The app's `ScriptHost.power(for:)` reads the table,
and so does the lint. A test lists every Janet function the module offers and checks it against the table, so
`api-version` is the only function without a row. No call maps to a host launch in the table. A layout carries its
launch, so the lint treats a literal `request-layout` call as needing host-launch when a struct inside it has `exec` as
a key, spelled as a keyword or a string. It treats a declared host-launch as used by any `request-layout` call.

A reference to a module function counts as a use of its power, whether it is called, aliased, or passed. The lint
resolves `(import uniterm)`, `:as`, `:prefix`, and `(use uniterm)`, from imports found anywhere before the walk. It
tracks local bindings from `def`, `var`, `defn`, `fn`, `let`, `each`, `for`, `loop`, `with`, and `try`, so a local
named like a module function is not a call. A macro defined in the file is walked with its templates, so a template
that names a module function counts, and one that builds a name is a dynamic call. A name that starts with an imported
prefix and is not a module function is reported as one uniterm does not offer.

These reach a call without its name and are reported as able to make any call: `eval`, `eval-string`, `compile`,
`run-context`, `dofile`, `load-image`, `unmarshal`, `require`, `import*` or `use` with a computed path, `parse`,
`parse-all`, the `parser/` functions, `symbol`, `keyword`, `curenv`, `make-env`, `env-lookup`, `root-env`, `resolve`,
`fiber/getenv`, `fiber/setenv`, the `module/` tables, and `dyn` with a computed key or the environment. `apply` is not
on the list. A function reaches `apply` only through a literal reference, which is counted where it appears, or through
one of these. Once a file has a dynamic call, the lint reports no declared power as unused. A declared capability is
never reported unused.

An undeclared file lints too. Each call reports its power as undeclared, and a last line suggests the declaration to
add. A `comment` form is data unless the file binds its own `comment`. Limits: `match` and `case` patterns are not seen
as bindings, a file the script imports is not scanned, quoted code outside a macro is data, and a launch hidden behind
an alias of `request-layout` is not seen.

The lint walker is in the declaration fuzzer's run: the fuzzer lints mutated files twice and compares the results.

## Decision Log

- 2026-11-13: Drafted from hands-on review of the Pending Requests panel. The user chose an embedded declaration over a
  scanner as authority, and a dedicated form over a `def` for its loud typo behavior. The user chose
  `declare-permissions`, outside the `uniterm/` namespace. The user chose literal data, a single declaration at the
  start, and `controller.json`'s vocabulary.
- 2026-11-13: The user chose a detached `.sig` sidecar for signing, and an optional `:id` and `:name`, required when
  signed.
- 2026-11-13: The user chose strict mode by default, with an unsafe mode whose choices last one run. The user chose an
  app setting with no run flag, and the pane rules for Ask Each Use.
- 2026-11-13: The user chose to refuse undeclared powers outright, with no offer to allow them.
- 2026-11-13: The user chose "Allow for This Run" everywhere, including plain-script questions.
- 2026-11-13 (addition): The user added the lint to this proposal.
- 2026-11-13: The user kept REPL panes out of scope.
- 2026-11-13: ADR candidate (cuts across the system): script files run strict by default, refusing a file that declares
  nothing. Declined: ADR-09 already requires an explicit grant for every effect, and the strict default applies it.
- 2026-11-13: ADR-09 check. Allow Everything is written as a grant of three named powers, revocable and checked at the
  boundary, to match "an explicit, revocable grant covering the operation". An unsigned file's trust is version trust
  only. Identity trust needs a signature and an ID, to match "digests ... are insufficient proof of script identity".
- 2026-11-13: Review start: 5 milestones, 10 settled decisions, 5 risks, no Live after lines or row gates; out of
  scope: REPL panes and packages; at commit "Draft UTERM-021: declared permissions for script files". The user asked
  for an autonomous review of the four open questions.
- 2026-11-14 (autonomous): The authenticated command parses the snapshot and reports the declaration. A sandboxed
  parse helper protects only a parse an attacker routes around, a Swift reader adds a second grammar, and Janet in the
  app breaks ADR-07. Converged in 1 pass.
- 2026-11-14 (autonomous): One run per command process, so script code on a second connection cannot begin a trusted
  file under its standing powers or forge the declaration a review shows. Found in the first critique pass.
- 2026-11-14 (autonomous, addition): The one-run rule covers packages too. A second connection can begin a trusted
  package today and run under its standing powers without review. This brings in a refusal for packages, a gap the
  proposal exposes but does not create.
- 2026-11-14 (autonomous): Closed sets are keywords, including capability names, and free text is strings, with no
  format number. Converged in 1 pass.
- 2026-11-14 (autonomous): A declared file cannot declare capabilities that load native code, as a package cannot. A
  script that needs one runs only undeclared in unsafe mode. Found in the first critique pass.
- 2026-11-14 (autonomous): The lint is `uniterm lint file.janet`. `run --check` would run the script when the flag
  lands after the path. Converged in 1 pass.
- 2026-11-14 (autonomous): The mode is a "Script files" row on the Settings page. A switch to strict refuses waiting
  undeclared-file reviews. Converged in 1 pass.
- 2026-11-14 (autonomous): Coherence pass. Strict mode governs the bundled command only. Generic peers keep UTERM-004's
  admission, and undeclared files keep today's unsnapshotted path. Refusing every plain begin would have broken
  generic peers that UTERM-004 keeps, for no gain under ADR-09's same-user limit.
- 2026-11-14 (autonomous): Coherence pass. File approvals get their own policy file and selectors. The controller
  policy reader moves aside a file with an unknown selector kind, so shared records would cost an older build every
  controller approval.
- 2026-11-14 (autonomous, addition): Coherence pass. The one-session rule counts a REPL attach, so pasted REPL code
  with `net-connect` cannot begin a trusted run. This extends the package addition to REPL helpers, which are
  otherwise out of scope.
- 2026-11-14 (autonomous): Coherence pass. A native entry's connections after exec are all adopted, since the whole
  process is the controller.
- 2026-11-14 (autonomous): Coherence pass. Allow Everything grants the two clipboard powers only. Pane calls already
  follow the pane rules under Ask Each Use, so listing pane control claimed a difference that does not exist.
- 2026-11-14 (autonomous): Coherence pass. Comments may precede the declaration, a declared file's loader resolves
  uniterm's bundled modules, REPL and generic-peer questions keep "Allow for This Connection", and the example's
  shebang uses `env -S`. The undeclared-power rule now names declared files and controllers only. Fourteen
  implementation findings went to milestone checks: M1 got 1, M2 got 7, M3 got 2, M4 got 2, M5 got 2.
- 2026-11-14 (autonomous): Re-check pass. An undeclared run from the bundled command sends an undeclared begin and
  waits for the app's answer before running anything. Today's plain begin gets no answer, so a file would have run
  before strict mode refused it or the unsafe review was answered. A generic peer's plain begin is unchanged. Eight
  implementation findings went to milestone checks: M2 got 6, M4 got 2.
- 2026-11-14 (autonomous): Risk review. Added the accepted risk that strict mode does not stop a generic peer, under
  ADR-09's same-user limit. The ScriptWire bump and the new file policy file are versioned, so neither is an
  unlisted one-way door. No risk is rated high likelihood and high impact.
- 2026-11-14 (autonomous): Second re-check pass converged. Three implementation findings went to M4 and one widened
  an M2 check. The Impacts line for UTERM-003 now says undeclared runs wait for the app's answer.
- 2026-11-14: Review gate: kept all, including both one-session additions for packages and REPL helpers.
- 2026-11-14: The user accepted the proposal.
- 2026-11-14: Scheduled as M1-M5 in queue.md.
- 2026-11-14: ADR candidate (cuts across the system): one session per command process, for files, packages, and REPL
  helpers. Declined: ADR-09's authenticated binding to the actual run already covers it.
- 2026-11-15 (run best guess): A host launch is listed once for each executable alone, as `controller.json` lists
  it, so two host launches of one executable in different directories are a repeated kind. The decision said "once for
  each scope" and did not say what a host launch's scope is. Amended text: "A scoped kind, such as a capability or a
  host launch, is listed once for each scope." It now says a capability is listed by its name and a host launch by its
  executable alone. A declaration that wants two directories for one executable lists the broader directory.
- 2026-11-15 (run best guess): A script file's signature domain line is `uniterm script file 1\n`. The decision said
  "a fixed domain line" and did not name it, and the line has to differ from the descriptor's so neither kind of
  signature verifies the other. Amended text: the Signing decision now names both lines. If a different line is
  wanted, only the one constant and the signatures made so far change.
- 2026-11-15 (run best guess): The package tests' script fixtures stay undeclared. The SwiftPM test helper that runs
  them is not the bundled command, so the app takes it for a generic peer, which UTERM-004 admits in strict mode, and a
  declared file from it is refused because only the bundled command may begin one. Declaring them would have moved
  every one of those tests onto the signed copy of the command, with a review answered in each. The M4 check said "the
  repo's script fixtures and examples carry declarations". Amended text: it now names the scripts the UI tests run
  through the bundled command, and says the package fixtures stay undeclared and why. The repo has no other script
  examples. If declared fixtures are wanted anyway, those tests move to the signed command and answer a review each.
- 2026-11-15 (run best guess): An app refusal of a run makes the command exit 77 (EX_NOPERM), where it exited 69. The
  proposal names no exit status. The change came from review: scripts that loop while the exit is 69, meaning no app
  is up yet, would retry a strict-mode refusal for the whole retry window. 69 stays for no reachable uniterm. UTERM-003
  names the sysexits statuses as public contract, so its list is stale by this one. Only an answer from the app counts:
a socket that belongs to another user never reached the app, so it keeps 69.
- 2026-11-15 (run best guess): Revoke on an undeclared run ends its authority and does not stop the process. The
  Where-the-mode-setting-lives decision and the M4 check said a live run "keeps running" and that Revoke "ends it". A
  controller run's Revoke and a declared file run's Revoke refuse the run's later calls and leave the process and its
  connection alone, so the undeclared run does the same. Amended text: the decision now says the user ends the run's
  authority, as for a controller run, and the check says its next call is refused. If a stopped process is wanted,
  Revoke would close the connection for all three kinds of run, which is a separate decision.
- 2026-11-15 (run best guess): The lint reports no declared power as unused once it finds a dynamic call, and its
  exit status is 0, 1, 65, or 66. The decision said a dynamic call makes the lint report that the file could make any
  call, and named no exit status. A file that could make any call may use any declared power, so an unused report
  would be a claim the lint cannot back. Amended text: "The lint" now says both. If the lint should still list the
  declared powers it saw no literal use of, only the one suppression changes.
- 2026-11-15: Correction of fact to the Risks section's first bullet. It said "The repo's own fixtures and examples gain
  declarations in the same milestone. Unsafe mode runs an undeclared file after one review per run. A declaration plus
  Trust This Version removes the review until the file changes. No setting restores today's run with no review at all,
  which is the point of the change." The package tests' script fixtures stay undeclared, and the scripts the UI tests
  run through the bundled command carry declarations or run in unsafe mode, as the fixtures entry above records. The
  bullet now says that, and its other sentences are unchanged.

- 2026-11-16: Superseded in part by UTERM-032. A file policy that holds a remembered input folder lives in a third
  store beside the two policy files, so an older build's file trust keeps working beside a newer build. A declared file
  also gains the `input-file` permission kind.
- 2026-11-22: Superseded in part by UTERM-034. The command reads a declared file once with the invoker's access, and
  sends its bytes and its `.sig` to the app. The app hashes the bytes it receives and verifies the signature, and
  writes no snapshot. This replaces the app's read and snapshot in "The file is snapshotted and hashed", "Where the
  declaration is read", and "Authority comes from the read, not the run", M2's snapshot checks, and M3's note that the
  app reads the `.sig`.
- 2026-11-23: Superseded in part by UTERM-056. Once it lands, the app refuses an older command at its begin instead of
  at the hello. A program that is not the command and sends an undeclared or open begin from an older version is refused
  too, until it is rebuilt.
- 2026-11-26: Superseded in part by UTERM-067. File approvals no longer live in a policy file of their own. Every
  approval lives in `policy.json`, and each entry names its artifact kind, so a file approval and a package approval
  are still never read as each other's.

## References

- ADR-07: failure isolation. Scripts still run in the command's process.
- ADR-09: control authority requires authenticated identity and explicit scope.
- ADR-10: helpers that need no file or network access run sandboxed. It bears on where the declaration is read.
