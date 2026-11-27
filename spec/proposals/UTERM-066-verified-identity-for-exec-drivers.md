# UTERM-066: Verified Identity for Exec Drivers

**Status:** accepted
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- UTERM-004: exec drivers, their launch, and controller verification ("Verified artifact and run binding")
- UTERM-063: permission descriptors and the layout-request API stay at version 0, so the new declaration field lands
  in place
- UTERM-028, UTERM-055, UTERM-065: M2 remembers the command, capture, and read-scope powers they define. Each part of M2
  waits on its proposal's power being built

## Impacts

- UTERM-004 — "Permission scopes and approval flow": a controller's `host-launch` grant never covers a package's
  launch, so its scope narrows to drivers with no package.
- UTERM-004 — "Exec launch context" and "Saved layouts": a declaration may name a package, and the layout saves it.
  "Verified artifact and run binding": the app, not the `uniterm` command, spawns a verified native entry for a
  driver, so the app must refuse `DYLD_` variables itself. "Verified artifact and run binding" also says other
  interpreters need "an equally verifiable loader" before script trust, that ambient module paths and startup hooks
  "cannot select substitute dependencies", and that exec invalidates the live binding. For a verified driver, C2 and
  "Trust covers what uniterm verified, and says so" replace the first two, and "A run is bound to its channel and
  snapshot" replaces the third. UTERM-004 is implemented, so its text stays, and it gains "Superseded in part by
  UTERM-066" markers when this proposal is accepted.
- UTERM-004 — "Verified artifact and run binding": a packaged path component may start with `_`, a descriptor may list
  folder names to skip, and a descriptor names one role, per "Python's own file names can be packaged" and "A
  descriptor names one role". The policy file moves to format 3, with every approval in `policy.json`, per
  UTERM-067 and "Version skew". Amended 2026-11-27; see Decision Log.
- UTERM-028 — "How a driver gets the power": "Nothing is remembered across runs, since a driver has no verified
  identity" holds only for a driver with no verified identity.
- UTERM-055 — "Which grant and targets an exec driver captures under": a verified driver may keep a remembered
  approval for capture.
- UTERM-065 — "How long the grant lasts": its revisit hook names this proposal. A verified driver may keep a remembered
  read scope. "The driver asks at run time": a verified driver's request for directories its package did not declare
  is denied, per "A verified driver declares the access it needs". A driver package may declare its starting folder as
  its read scope, a form a controller's descriptor lacks. The granted scope stays the absolute folders UTERM-065
  defines, per "A package may declare its starting folder as a read scope".
- UTERM-048 — "A plain script or a driver is never labeled verified": a verified driver is labeled with its identity.
- Driver clipboard and browser grants (UTERM-004, UTERM-019): a verified driver may keep remembered approvals for them.

## ADR Deviations

- ADR-14 P9 under C2: "Script files are verified too" verifies a script an interpreter driver names, through a
  snapshot uniterm makes, and starts the interpreter with a command line the descriptor fixes. C2 covers it. What a
  remembered approval trusts without checking is the code the script imports at run time, the interpreter's install,
  and its startup files, per "Trust covers what uniterm verified, and says so".

## Summary

An exec driver can be a verified package, as a controller is. uniterm snapshots and verifies it, and starts the
verified copy. A verified driver can then keep remembered approvals, "Trust this version" or "Trust this identity", for
its per-run powers. A driver with no package works as it does today, asking again every run.

## Motivation

A driver is known only by the absolute path in its argv. No code hashes or verifies the executable. Anything can
replace the file at that path between runs, so ADR-14 P9 lets a driver keep no remembered approval. Every power a
driver holds today asks again on every run: clipboard and browser. So will the powers accepted or drafted for drivers:
commands under UTERM-028, capture under UTERM-055, and the read scope under UTERM-065.

Controllers already have the machinery a driver lacks. UTERM-004 verifies a `controller.json` descriptor, its file
digests, and an optional Ed25519 signature, snapshots the package into a private run folder, and checks a native
entry's load commands. Remembered approvals live in `controllers/policy.json`, and script files in `files.json`. This
proposal brings that machinery to drivers. The user asked for it on 2026-11-26, while filing UTERM-065.

A native program can already earn remembered trust today, as a native controller started by `uniterm run`. What a
driver adds is the exec contract: uniterm starts it in a pane, and it talks over stdin and stdout with applet events.
A script in a language other than Janet has no verified form today in either role.

## Design Decisions (Settled)

### A declaration may name a package

Decision: an exec declaration may name a package folder in place of a bare executable. The package uses UTERM-004's
descriptor, digests, and optional signature. uniterm copies it into a private run snapshot, verifies the copy, and
spawns the snapshot's entry. A declaration with a bare executable keeps working as today, with no verified identity.

**Decided by:** user, 2026-11-26

Rationale: the snapshot covers the entry and every packaged file it loads, and reuses code that already verifies
controllers. Hashing only the executable would leave the libraries and data it loads unverified. System libraries stay
outside the package, as UTERM-004 allows for a native entry.

### Script files are verified too

Decision: a script driver's descriptor fixes its whole command line. It names the interpreter's command, the
interpreter's flags, and the script, which is a file the descriptor lists. The interpreter's path is the user's
binding, per "The user binds a script driver's interpreter". uniterm snapshots and verifies the script with the package,
and the interpreter runs the snapshot copy. The declaration supplies only the arguments after the script. The
descriptor lists the environment key names a declaration may supply, and a package declaration that names any other
key is refused, for every driver package, native or script. The user types each value, as for any exec declaration. A key the author
lists, such as `HOME`, is the author's verified choice. Amended 2026-11-26; see Decision Log.

**Decided by:** user, 2026-11-26

Rationale: most drivers are scripts. Leaving them out would keep every script driver asking each run. Fixing the
command line in the signed descriptor closes interpreter flags and scripts outside the signature. Listing the keys in
the descriptor closes the environment for every interpreter. A refused-key list per interpreter could never cover
"Any interpreter the user has may run a driver": Lua reads `LUA_INIT`, zsh reads `ZDOTDIR`, and each new interpreter
brings its own. What trust says about the interpreter is settled in "Trust covers what uniterm verified, and
says so". Imports stay unverified, which is the deviation from ADR-14 P9 recorded above.

### Any interpreter the user has may run a driver

Decision: a script driver may name any interpreter the user has, including a Homebrew install, a local build, or a
virtual environment. uniterm adds no limit on which interpreter a driver uses, on how it is installed, or on how the
user has set it up, and no such limit decides whether a driver can keep a remembered approval.

**Decided by:** user, 2026-11-26

Rationale: uniterm does not control how a user installs or uses interpreters, and may not add artificial limits on
them.

### The user binds a script driver's interpreter

Decision: a script driver's descriptor names its interpreter as a command, such as `python3`, and may suggest an
absolute path. The user picks the interpreter's absolute path on the package's first launch, in the launch prompt,
and every later launch shows it. uniterm keeps the pick in a store of its own, apart from approvals, keyed by the
package's ID, its interpreter command, and its signing key when it is signed. It survives a new version and a revoked
approval. A launch whose ID, command, or key matches no binding asks for one. The user can change a binding in
Controllers & Permissions. A declaration never supplies it, and nor does a program. ADR-14 C2 counts the user's binding
as part of the fixed command line. Amended 2026-11-26; see Decision Log.

**Decided by:** user, 2026-11-26

Rationale: a pyenv or virtual-environment Python lives under the user's own home folder, and a Homebrew one sits in a
different prefix on Intel and Apple silicon. An author cannot name it for anyone else, and uniterm does no PATH search.
An absolute path in the descriptor would leave a package the user did not write unable to use the user's interpreter
without re-signing it, which loses its author's identity trust. A path from the declaration would let a program's
layout request pair a trusted package with its own binary, which would then use the package's remembered powers.
Keeping the pick apart from approvals keeps it through Allow once, which stores no approval, and through each new
version under "Trust this version". Authors choose IDs freely, so an ID alone would let an unrelated package with the
same ID, or a new version that changed its command from `python3` to `node`, run under another package's interpreter.
The command closes the second case for every package. The key closes the first for signed packages. Two unrelated
unsigned packages with one ID and one command still share a binding, since an unsigned package has nothing beyond
its ID to tell a new version from another package. Every launch shows the bound path, and the binding grants no power.

### A descriptor names one role

Decision: a descriptor names the one role its package serves, controller or driver. The role decides which entry kinds
and which powers the descriptor may declare, and a mistake fails when the package is signed or read. A driver accepts
a native entry or an interpreter entry. A controller accepts today's entry kinds only. A descriptor with no role reads
as a controller. `uniterm run` refuses a driver package by name, and a pane refuses a controller package by name. A
program wanted in both roles ships as two packages, which may share an ID and a signing key.

**Decided by:** user, 2026-11-26

Rationale: one role per descriptor makes an invalid package a load error, not a protocol failure at launch. A
descriptor with a section per role would tie both roles to one version digest, so editing only the driver part would
ask again for the controller's "Trust this version". No program in any proposal needs both roles. A Janet script
driver uses an interpreter entry that names the user's `janet`. UTERM-004's Janet entry runs inside the `uniterm`
command's own VM, which is a controller's contract.

### Python's own file names can be packaged

Decision: a packaged path component may start with `_`. A leading `.` or `-` stays refused. A descriptor may list
folder names that the package check, the signer, and the snapshot copy all skip, at any depth, such as `__pycache__`.
A skipped folder that holds a listed file is refused when the descriptor is read. This holds for every package.

**Decided by:** proposal-reviewer (autonomous), 2026-11-26

Rationale: UTERM-004's path rule refuses `__init__.py` and `_internal.py`, so no Python library could be vendored
into a package, and vendoring is the only way to bring imports inside what uniterm verifies. Homebrew's Python writes
`__pycache__` beside each imported module when the author tests the script, and the package check then refuses the
package. A leading underscore gives no path a second spelling and climbs out of nothing. The author lists the skipped
names, so uniterm infers nothing, per "Trust covers what uniterm verified, and says so". Copying only the listed files
instead would lose the check that catches a module the author forgot to list. That module would then fall through to
the interpreter's own search path and run unverified under the driver's remembered powers.

### A package may declare its starting folder as a read scope

Decision: a driver package may declare its read scope as the folder it starts in, and every folder inside it. A run
resolves that folder once, with every link resolved, and uses the same resolved path as its working directory and as
its scope. A remembered approval stores the resolved absolute folder, as any read scope does. A later run whose
starting folder that approval covers needs no prompt. A run started in a new folder asks once, in the start review, as
a broader scope, and approving it adds that folder to the approval. The launch approval never grants the scope.

**Decided by:** proposal-reviewer (autonomous), 2026-11-26

Rationale: a signed driver cannot know the user's project folder, and a declared absolute folder cannot reach
`~/Documents` for someone else's home. Without this, the only way to read a user's folder is to run the script bare,
which gives up verification. Remembering the declared form itself would let a later layout request start the same
version at `/` and reach it with no review, against ADR-14 P10 and UTERM-065's rule that the launch approval never
grants the scope. Storing the resolved folder keeps the granted scope the same type UTERM-065 defines.

### Trust covers what uniterm verified, and says so

Decision: a remembered approval for a verified driver covers the packaged files and the command line the descriptor
fixes, and nothing else. uniterm never claims more. For a script driver, the interpreter's install, its startup files,
the modules it imports, and the user's own setup are outside what uniterm verifies. For a native driver, so are the
system libraries it links. The review text says what is verified and what is not, in plain words. uniterm asks again
when the verified files change, not when the interpreter or the system changes.

uniterm never attempts to inspect a script or its interpreter, whether to find what it imports, what it loads, or what
it might do. The package holds exactly the files its author lists, and nothing uniterm infers. The trust boundary is
the access a program declares, not anything uniterm works out about its code. Amended 2026-11-26; see Decision Log.

**Decided by:** user, 2026-11-26

Rationale: no driver can be fully isolated by verifying its files. A script runs inside an interpreter the user set up,
and a binary links system libraries uniterm does not ship. Claiming isolation that does not exist would mislead the
user about what they trusted. Asking again on every interpreter or package upgrade would only train the user to click
through prompts, and still not stop a same-user process, which UTERM-004 already accepts can edit a controller's
snapshot. A user who needs the most isolation uniterm can give packages a native binary with its libraries inside it.

### Remembered approvals cover every per-run power

Decision: a verified driver may keep a remembered approval for each of its per-run powers: clipboard, commands,
capture, and the read scope.

**Decided by:** user, 2026-11-26

Rationale: identity is what P9 asks before any approval is remembered. Once a driver has one, no power has a reason to
stay per-run that a controller's same power lacks.

### The same two trust levels as controllers

Decision: a verified driver offers "Trust this version", for the exact verified bytes, and "Trust this identity", for
a signing key plus the driver's ID across signed versions. Both live in the controllers' policy file.

**Decided by:** user, 2026-11-26

Rationale: the two levels mean the same thing for a driver as for a controller. One store keeps one place to review
and revoke trust. uniterm is pre-v1, so an older build that cannot read a driver entry is not a constraint.

### Each approval names its artifact kind

Decision: every entry in the policy store names its artifact kind, such as a controller package or a driver package. A
selector matches only runs of its own kind. A program shipped as a controller package and a driver package that share
an ID and a signing key has two entries, one per role, each with its own powers. Revoking one leaves the other.
Amended 2026-11-26; see Decision Log.

**Decided by:** user, 2026-11-26

Rationale: ADR-14 P8 says one granted power never silently grants another. Trusting a package to read the clipboard as
a driver in a pane must not let it do so as a controller started from a shell. The code already keeps script-file and
package approvals apart for the same reason. The window can still group the entries that share an ID and a key, so
they read as one program with two roles.

One entry with a list of roles was weighed and rejected, for two reasons:

- The roles carry different powers. As a driver, a package might hold the clipboard and a read scope. As a controller,
  it might hold pane control. One entry would mix two approvals, so editing one role's powers would mean touching the
  other role's entry.
- It suits ADR-18. When a newer build adds a role an older build does not know, separate entries let the older build
  skip that one whole entry and keep the rest. A list of roles would put an unknown value inside an entry the older
  build otherwise reads, which ADR-18 P4 rules out.

### A verified driver declares the access it needs

Decision: a driver package declares in its descriptor every power it needs, as a controller does. The user reviews the
declared powers when the driver starts. A request for a power the package did not declare is denied, whatever the
driver's identity or trust. A driver with no package keeps asking at run time, as today.

**Decided by:** user, 2026-11-26

Rationale: the trust boundary is what a program declares, per "Trust covers what uniterm verified, and says so". A
program whose declaration is wrong, and that asks for something it never declared, is denied rather than asked again.
UTERM-004 already refuses an undeclared effect "even when the controller's identity is trusted".

### Where a package declaration can come from

Decision: a package declaration may come from a layout file, from the UI, or from a program through the layout-request
API, like any exec declaration. A controller's `host-launch` grant never covers a package's launch, so every launch of a
package asks, through UTERM-004's launch approval.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: a declaration only places a driver in a pane. Nothing runs until the user presses Run and approves the
launch, so a program declaring a package gains nothing by itself. A `host-launch` grant that covered a package would
skip the only prompt that shows its arguments. A controller could then start a trusted relay driver pointed at a host
it chose, and use the driver's remembered powers without holding them, against ADR-14 P8. Keeping packages out of
`host-launch` also leaves its scope and the policy format unchanged.

### A layout saves the package's absolute path

Decision: the layout saves a package declaration as the package folder's absolute path, beside the arguments after the
script, the directory, and the environment key names. A package that has moved fails to launch, and the pane says
where it looked. The layout envelope moves to version 4.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: verification and the launch prompt run on every launch, so the path is all a launch needs. A bookmark would
add a second way to find the package, and the prompt would then have to say where it found it. uniterm is pre-v1, so
the envelope bump costs nothing, and ADR-06 keeps a newer file aside in an older build.

### The launch is never remembered

Decision: a verified driver's launch asks as today, through UTERM-004's launch approval. A `host-launch` grant never
covers it, per "Where a package declaration can come from". Remembered approvals cover the driver's powers, never its
launch.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: the launch prompt is the only place the user sees the arguments a driver starts with. A pane a program laid
out could otherwise start a trusted package with arguments the user never saw, and a relay driver such as `ssh host`
would reach whatever host the arguments name. A remembered launch would also be a new remembered power, beyond the
per-run powers this proposal covers.

### A run is bound to its channel and snapshot

Decision: the app spawns the snapshot's entry itself, and binds the run to the channel it created and the snapshot it
made, until the driver exits. Every use of a remembered power checks that binding. Code the driver starts, such as an
interpreter's own re-launch or a child process, inherits the channel, and is outside what uniterm verified, as "Trust
covers what uniterm verified, and says so" states. A package declaration that names a `DYLD_` key is refused, so no
library is injected at spawn. Amended 2026-11-26; see Decision Log.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: the app already holds the driver's pipe, so there is no peer to authenticate, and a second launcher would
add nothing. The channel is what the transport can establish, per ADR-14 P13. A rule that ended identity on exec would
end it for a Homebrew Python before the script's first line, since its framework launcher re-spawns into Python.app,
and for shims such as pyenv's. That would break "Any interpreter the user has may run a driver". It would also block
nothing, since a driver can fork a child that execs anything with the inherited channel.

### Version skew

Decision: uniterm is pre-v1, so each contract may break, and the behavior is stated rather than made tolerant.

- The policy store: one file, `policy.json`, holds every approval at UTERM-067's format 3, and every entry names its
  kind. A build in use today reads it as newer, or moves it aside when it cannot parse it whole, and UTERM-067's
  "Version skew" and "Old trust files are set aside" govern the loss. Amended 2026-11-27; see Decision Log.
- The layout file: an older build keeps a version 4 file aside, per ADR-06.
- The descriptor, which gains a role, driver kinds, an interpreter entry kind, an interpreter command, skipped folder
  names, a list of environment keys, a starting-folder read scope, and a fixed command line: an older build refuses a new package by name, through
  strict parsing. A newer build reads an old package unchanged, as a controller.
- The interpreter binding store: an older build never reads it. A newer build that finds no binding for a package asks
  for one at launch.
- The layout-request API's package field: an older app refuses a new caller by name, which UTERM-063 allows at version
  0.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: the user accepts breaking changes before v1. Each failure is a refusal by name or a kept file, never a
silent grant, so none fails open.

### ADR-14 gains a carve-out for verified scripts

Decision: ADR-14 gains a carve-out to P9, C2, with the text below. The user approved it on 2026-11-26, and it is in
ADR-14.

> **C2** (relaxes P9): A script run by a shared interpreter may hold a remembered approval when uniterm itself
> snapshots and verifies the script and every file its package declares, and starts the interpreter the user chose with
> a command line those verified files fix. Only the user chooses the interpreter, never a program or a declaration.
> No argument from outside the verified files comes before the script, and no environment key
> the interpreter or the loader reads as a hook comes from outside the verified files. Settings that change where the
> interpreter finds its startup files, such as `HOME`, are outside what uniterm verifies, and the user is told so. The
> proof of identity is uniterm's own verification, not a name, path, or digest the script or its runner claims. The approval
> covers only the verified files and the access they declare. The interpreter, its install, and whatever the script
> loads beyond its package are outside it, and the user is told so. Verifying files cannot isolate a program from the
> system it runs on, so the approval states its boundary rather than claim one it cannot hold.

**Decided by:** user, 2026-11-26

Rationale: P9's concern is a program borrowing trust by claiming to be an approved script. A snapshot uniterm makes
and verifies is not a claim. A carve-out keeps ADR-14 the full statement of its rule, where a deviation would leave the
exception only in this proposal. The carve-out names a condition, not this proposal, so a later script runner that
meets it may apply it too.

## Design Decisions (Open)

None.

## Risks

- **Code outside the verified files runs under remembered powers** — likelihood: low, impact: high. A flag such as
  `python3 -c`, or a hook such as `PYTHONSTARTUP`, could run code no digest covers. So could a same-user process that
  changes the interpreter's install, or a system library a native driver links. Mitigation: the descriptor fixes the
  command line and lists the environment keys a declaration may name, per "Script files are verified too". Accepted for the rest: the interpreter,
  its startup files, and system libraries are outside what uniterm verifies, and the review text says so, per "Trust
  covers what uniterm verified, and says so".
- **A verified script driver imports unverified code** — likelihood: high, impact: medium. An interpreter loads modules
  from its own search paths. Mitigation: the review text says imports are not verified, and "Trust this version" binds
  only the packaged files. Accepted under ADR-14 C2.
- **An older build trusts no controller** — likelihood: medium, impact: low. The policy file is at UTERM-067's format
  3, so a build in use today trusts no controller from it, per "Version skew". Accepted: uniterm is pre-v1, and the
  user accepts breaking changes until then. Amended 2026-11-27; see Decision Log.
- **The interpreter binding is stored data** — likelihood: medium, impact: low. Every later build reads the binding
  store. A wrong binding runs the wrong interpreter under the package's remembered powers. Mitigation: only the user
  sets a binding, every launch shows it, and the binding grants no power. A store a build cannot read asks for a new
  binding at launch.
- **A remote party behind a trusted driver** — likelihood: low, impact: medium. "Trust this version" of a packaged
  ssh-like driver remembers powers for whatever host its argv names. The approval binds the local code, not the remote
  party. Mitigation: "The launch is never remembered", and a `host-launch` grant never covers a package. Every new
  declaration's launch shows its arguments to the user. An Allow in This Pane grant relaunches the same pane's
  declaration, which cannot change under the grant.
- **A same-user process edits the snapshot** — likelihood: low, impact: medium. UTERM-004 notes that read-only files
  are not immutable against a malicious process of the same user. Accepted: the same holds for controllers today.
- **The design depends on proposals still in flight** — likelihood: medium, impact: medium. UTERM-028, UTERM-055, and
  UTERM-065 are accepted and not started, and UTERM-063 changes permission editions underneath. ADR-18 is proposed, and
  UTERM-067 is accepted and not built. The second reason for one policy entry per role rests on ADR-18 P4. Mitigation: M2's parts wait
  on each power, per Dependencies. The first reason for one entry per role, that the roles carry different powers,
  holds without ADR-18.
- **The descriptor's new fields are a signed contract** — likelihood: medium, impact: medium. Authors sign descriptors
  that name a role, an interpreter command, skipped folders, environment keys, and a starting-folder scope, and every
  later build must read them with the same meaning. Mitigation: strict parsing refuses an unknown field by name, a
  newer build reads an older descriptor unchanged, and a descriptor with no role reads as a controller, per "Version
  skew".
- **A layout's package declaration is stored data** — likelihood: medium, impact: medium. Every later build reads it.
  Mitigation: ADR-06's versioned envelope, and "A layout saves the package's absolute path".

## Milestones

### M1: Package declarations and a verified spawn

**Status:** NOT STARTED

- A declaration that names a package snapshots it, verifies the copy, and spawns the snapshot's entry
- A package whose descriptor, digests, signature, or load commands fail is refused, and nothing runs
- A package declaration that names a `DYLD_` environment key is refused before anything runs
- A native driver package declaration that names an environment key its descriptor does not list is refused
- A descriptor that lists a `DYLD_` key is refused when it is signed or read
- A layout request from a program can declare a package, and its launch still asks
- A controller's `host-launch` grant never covers a package's launch, on the controller-owned Run path too
- The run's binding and its snapshot last until the transport ends, not only until the spawned process exits, so a
  child that still holds the channel keeps its packaged files
- The launch approval and the review of declared powers come in one prompt, or launch first and review second
- The package is snapshotted and verified before the launch prompt shows, and the prompt names the verified identity
  and every power the package already holds through a remembered approval
- A moved package fails to launch, and the pane names the absolute path it looked at
- The layout is written at envelope version 4, and an older build keeps a version 4 file aside
- A declaration with a bare executable launches as today, with no verified identity
- A driver package declares its powers in its descriptor, which knows the driver's kinds. A driver package that
  declares a controller-only kind, such as `pane-control` or `host-launch`, is refused when it is signed or read
- A descriptor names its role. A descriptor with no role reads as a controller. `uniterm run` refuses a driver package
  by name, and a pane refuses a controller package by name
- An older build refuses a driver package by name
- A packaged path component may start with `_`, and one starting with `.` or `-` is still refused
- A folder name the descriptor lists to skip is skipped at any depth by the package check, the signer, and the copy,
  and the walk does not count its contents toward the entry bound. A skipped folder that holds a listed file is
  refused when the descriptor is read
- A package that declares its starting folder as its read scope resolves that folder once, and the driver's working
  directory and its scope are the same resolved path. The start review shows that concrete folder
- The user reviews a driver package's declared powers when it starts
- A verified driver's request for a power its package did not declare is denied, with no prompt
- uniterm never reads a packaged script or the interpreter to find what it imports or loads. A test shows a script
  importing an unpackaged module runs with no warning or bundling from uniterm
- Replacing the package's files after launch does not change what runs
- Snapshotting runs off the main thread, and the snapshot stays until the driver exits and is removed after
- A saved layout keeps a package declaration, and a restored pane runs nothing until the user presses Run
- The pane shows a verified driver's identity from its package, not the snapshot's folder name, and UTERM-048's
  inspector labels it verified

### M2: Remembered approvals for a verified driver

**Status:** NOT STARTED

- The start review of declared powers offers "Trust this version" and "Trust this identity" for a verified driver's
  clipboard, browser, command, capture, and read-scope powers
- A remembered approval covers the next run of the same version or identity with no prompt
- A remembered power used after its run ended is refused, whether through a stale channel, an earlier run, or a removed
  snapshot
- A changed package asks again under "Trust this version", and a package signed by another key asks again under "Trust
  this identity"
- Under "Trust this identity", a newer signed version that declares an added or broader power asks for the difference
  only, per ADR-14 P10
- A driver with no verified identity is never offered a remembered approval
- A driver approval never covers a controller run of a package with the same ID and key, and a controller approval
  never covers a driver run
- A controller package and a driver package that share an ID and a key show two entries, grouped as one program, and
  revoking one leaves the other
- A remembered starting-folder scope covers a later run started inside a folder it holds, with no prompt. A run in a
  new folder asks once, and approving it adds the folder
- An approval whose read scope holds more than 32 folders reads back, and the policy file is not moved aside
- A remembered starting-folder scope does not cover a run started in a protected location it leaves out, such as one
  under `~/Documents` when the scope holds `~`. That run asks
- A driver approval is an entry in `policy.json` that names its artifact kind, beside every other approval. The file is
  always in UTERM-067's format 3, and a build in use today never reads it, per "Version skew". Amended 2026-11-27; see
  Decision Log
- Revoking a remembered approval removes it from the store, ends a live run's use of it, and stops its queued work
- Each use of a remembered power is checked at the effect, against the live policy

### M3: Verified script drivers

**Status:** NOT STARTED

- A driver whose entry is an interpreter runs the snapshot copy of its packaged script
- The interpreter's command, its flags, and the script come from the descriptor. A declaration can add arguments only
  after the script
- The first launch of a script driver package asks the user for the interpreter's absolute path, pre-filled with the
  descriptor's suggestion. Every later launch shows the bound path. The binding survives a new version and a revoked
  approval, and the user can change it in Controllers & Permissions
- A declaration or a program that supplies an interpreter path for a package is refused
- Two packages that share an ID but differ in interpreter command or signing key each ask for their own binding, and a
  new version that changes its command asks again
- A binding store this build cannot read is kept unchanged and never written over, and a binding picked at launch
  never replaces another package's binding. A pick made while the store cannot be read applies to that run only, and
  the launch prompt says it will not be kept
- Controllers & Permissions shows each binding's command and signing key, and changing one binding leaves the others
  with the same ID alone
- A skip name that is empty, holds `/`, or is `.` or `..` is refused when the descriptor is read, and skip names match
  folder names as APFS compares them
- A vendored Python library with `__init__.py` and `_internal.py` files imports from the snapshot, and a `__pycache__`
  folder the descriptor skips does not refuse the package
- A package declaration that names an environment key its descriptor does not list is refused before anything runs,
  for every interpreter, including one uniterm has never seen, such as Lua with `LUA_INIT`
- A key the descriptor lists, such as `HOME`, reaches the interpreter with the value the user typed
- A Homebrew interpreter, a locally built one, a pyenv-style shim, and one in a virtual environment each run a verified
  script driver and keep a remembered approval, across the interpreter's own re-launch
- A packaged multi-file script driver imports its packaged sibling modules under the flags the descriptor fixes
- An old build refuses a package with an interpreter entry by name
- A changed script asks again under "Trust this version"
- The review text names what stays unverified: imports, the interpreter's install, and its startup files

## Decision Log

- 2026-11-26: Filed while drafting UTERM-065, which defers a driver's remembered read scope until a driver has a
  verified identity. The user chose a controller-style package, verifying argv scripts too, remembered approvals for
  every per-run power, and both trust levels.
- 2026-11-26: Recorded the script decision as a deviation from ADR-14 P9 with no carve-out. P9 says a shared
  interpreter's identity and claimed digests do not prove a script's identity. The user chose it after the deviation
  was named.
- 2026-11-26: Critique pass 1, UNSOUND. Recorded two pending overrides. On "Script files are verified too": a replaced
  interpreter, interpreter flags, and environment hooks run unverified code, which is wider than the imports the
  deviation named. On "The same two trust levels as controllers": a shared policy file cuts off controller approvals
  in an older build. Widened the ADR Deviations entry to the full list. Added open questions on the interpreter entry,
  declared permissions, declaration sources, keeping driver and controller approvals apart, and version skew. Added
  options to the launch, run binding, and script argument questions, and the layout bump to the layout question.
  Corrected Motivation's list of powers and added the native controller path. Routed browser powers to an M2 check,
  since "every per-run power" already covers them, and left the decision's wording alone. Added risks, and
  Dependencies on UTERM-028, UTERM-055, and UTERM-065.
  Routed checks to M1 and M2. (new-proposal critique, override pending)
- 2026-11-26: Amended "Script files are verified too", by the user's choice after the critique. The descriptor fixes
  the whole command line: the interpreter, its flags, and a listed script. The declaration adds only trailing
  arguments, and interpreter hook keys are refused. It said before: "when a driver's entry is an interpreter, the
  script files its argv names are digested, snapshotted, and verified with the package." The user turned down limiting
  identity to native entries, and keeping the decision with the wider gap. Removed its pending override, narrowed the
  ADR Deviations entry to imports and the interpreter binary, and removed the open question on telling a script
  argument apart, which this settles.
- 2026-11-26: Critique pass 2, a re-check, NOT CONVERGED on one wording defect. An M2 check assumed driver approvals
  live apart from `policy.json`, against the user's storage decision. It now holds under whichever store is settled.
  Routed a check that an unwritable store turns off only its own trust choices. Clarified that M1 refuses `DYLD_` keys
  under either run-binding option.
- 2026-11-26: Critique pass 3, a re-check, NOT CONVERGED. Moved the older-build behavior out of an M2 check, which no
  implementation could pass under the user's storage decision, into "Version skew" with the behavior of each store.
  Recorded a pending override on "Script files are verified too": interpreter startup files, such as Python's `.pth`
  files and `sitecustomize`, run before the script, and a declared `HOME` moves them. Widened the ADR Deviations entry
  to name them. Routed the per-interpreter hook key list and the old-build refusal to M3.
  (new-proposal critique, override pending)
- 2026-11-26: Closing re-check, NOT CONVERGED, left to the user. An isolating flag such as Python's `-I` turns off the
  user's site folder only. The interpreter's own `site-packages` still runs `.pth` files and `sitecustomize`, and a
  Homebrew prefix is writable by the user. The ADR Deviations entry and the `-I` pending override do not name it. No
  design change was made for it. Corrected the ADR Deviations entry, which said the user chose after the full list was
  named. Routed `PERLLIB`, `BASH_FUNC_` keys, interpreter kinds with no isolating flag, and sibling imports to M3.
- 2026-11-26: The user kept driver approvals in the controllers' policy file, and declined the pending override for a
  separate `drivers.json`. Older builds do not matter before v1. Added "Each approval names its artifact kind", the
  user's choice, which settles the open question on keeping driver and controller approvals apart. Removed that
  question. The older-build risk is now accepted, and the M2 skew checks became role checks.
- 2026-11-26: ADR candidate (hard to reverse): a build never loses or disables stored data it can read because of
  stored data it cannot read. What it cannot read, it keeps unchanged and acts on nothing from. Raised by the user, who
  asked whether to adopt it before v1. Written as ADR-18, proposed, on 2026-11-26. It stays proposed until the user
  reviews it.
- 2026-11-26: Added "Any interpreter the user has may run a driver", the user's rule: Homebrew, local, and virtual
  environment interpreters must be allowed, and uniterm may add no artificial limits on interpreters. Withdrew the
  pending override for `-I` and a refused `HOME`, since `-I` stops `pip install --user` packages and the script's
  folder from loading. Replaced the open question "Which interpreter an entry may name", whose options limited
  interpreters, with "What remembered trust in a script driver covers". Updated the ADR Deviations entry, the
  substitution risk, and M3 to match. Dropped the M3 check on interpreters with no isolating flag.
- 2026-11-26: Added "Trust covers what uniterm verified, and says so", the user's choice. It settles the open question
  "What remembered trust in a script driver covers" as option A, and removes it. The user turned down asking again on
  an interpreter upgrade, and on a change to its startup files. Full isolation cannot be guaranteed from scripts, nor
  from a binary that links system libraries, and uniterm must not pretend otherwise. The substitution risk is now rated
  low likelihood and accepted for what lies outside the verified files, which ends its block on acceptance.
- 2026-11-26: Amended "Trust covers what uniterm verified, and says so", by the user's choice. uniterm never attempts
  to inspect a script or its interpreter, and the package holds exactly the files its author lists. The trust boundary
  is the access a program declares. The decision did not say before whether uniterm may look into a script's imports.
- 2026-11-26: Added "A verified driver declares the access it needs", the user's choice. A request for an undeclared
  power is denied. It settles the open question on what a driver package declares as option A, and removes it. The
  user turned down option B, where a driver declares nothing and each request is remembered on its own. Routed the
  descriptor's driver kinds, the refusal of controller-only kinds, the start review, and the no-inspection test to M1.
- 2026-11-26: Settled the four remaining open questions and version skew, on the user's instruction to keep going,
  using the recommendations already given to the user. A package declaration may come from any source, and a
  `host-launch` scope matches it by package identity. A layout saves the package's absolute path, at envelope version 4.
  The launch is never remembered. A run is bound to the spawned process until it execs. Skew is stated, not made
  tolerant, before v1. Turned down: a bookmark for the package, a remembered launch, and a second launcher.
  (autonomous)
- 2026-11-26: Drafted a carve-out C2 to ADR-14 P9 for verified scripts, for the user to approve. It waits on the user.
  (autonomous)
- 2026-11-26: Re-check of the settled questions, NOT CONVERGED on three design-level defects. Amended the run binding:
  it said identity ended when the process execs, and now binds to the channel and snapshot until the driver exits.
  Homebrew's framework Python re-spawns into Python.app before the script runs, so the exec rule broke "Any interpreter
  the user has may run a driver", and a forked child already inherits the channel. Changed "Where a package
  declaration can come from": a `host-launch` grant matched packages by identity, and now never covers one. With
  identity matching, a controller could launch a trusted relay driver at a host it chose and use the driver's
  remembered powers. Strengthened C2 to require that nothing outside the verified files changes how the interpreter
  starts. Routed checks to M1, M2, and M3. (autonomous)
- 2026-11-26: Closing re-check of the three fixes, NOT CONVERGED, on two defects. Removed "or a `host-launch` grant"
  from "The launch is never remembered", which contradicted the fix to "Where a package declaration can come from". The
  other goes to the user: C2 says nothing outside the verified files changes how the interpreter starts, but a declared
  `HOME` moves Python's user site folder, and no rule refuses it. No design change was made for it. Routed checks to
  M1, M2, and M3, and added UTERM-004's `host-launch` scope to Impacts.
- 2026-11-26: Narrowed C2, the user's choice. It said "Nothing from outside the verified files may change how the
  interpreter starts", which a declared `HOME` makes false, since Python finds its user site folder from `HOME`. It now
  promises only that no argument comes before the script and no hook key comes from outside the verified files, and
  says settings such as `HOME` are outside what uniterm verifies. The user turned down refusing `HOME` in package
  declarations.
- 2026-11-26: The user approved C2, and it was added to ADR-14. The ADR Deviations entry now reads "ADR-14 P9 under
  C2". It said before that this proposal departs from P9 with no carve-out.
- 2026-11-26: Recorded both reasons one entry per role beats one entry with a list of roles, at the user's request:
  the roles carry different powers, and ADR-18 P4 keeps an unknown role a whole skipped entry.
- 2026-11-26: Review start: 3 milestones, 14 settled decisions, 7 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; at commit "Add C2 to ADR-14: verified scripts may hold remembered approvals". The user asked
  for an autonomous review. No open questions remain, so it runs the coherence and risk reviews over the earlier
  autonomous decisions.
- 2026-11-26: Amended "Script files are verified too", the user's choice. The descriptor lists the environment keys a
  declaration may name, and any other key is refused, for every interpreter. It said before: "A package declaration
  that names an environment key the interpreter reads as a hook, such as `PYTHONSTARTUP`, `PYTHONPATH`, or
  `NODE_OPTIONS`, is refused." A refused-key list per interpreter kind could never cover "Any interpreter the user has
  may run a driver". The user turned down refusing interpreter kinds with no list, and running them with no check. A
  declared `HOME` is now refused unless the package lists it. Replaced M3's per-interpreter key list with checks.
- 2026-11-26: Clarified ADR-14 C2, the user's choice. "No argument comes before the script" now reads "No argument
  from outside the verified files comes before the script", which allows the interpreter flags the descriptor fixes.
  The meaning is unchanged, so ADR-14 gains no Amendments line.
- 2026-11-26: Review pass 1, a whole-proposal critique, UNSOUND. Verified its findings against the code. Rejected one:
  the run binding needs no ADR-14 P13 deviation, since the requester the proposal claims is the run the app's pipe
  establishes, not a single process. Fixed wording: UTERM-004's superseded clauses in Impacts, two stale risks, and
  the remote-party risk's claim that every launch shows its arguments. Routed checks to M1 and M2. Added five open
  questions, which the entries below settle.
- 2026-11-26: Added "A descriptor names one role", the user's choice. Amended "Each approval names its artifact kind":
  it said "A package trusted both as a controller and as a driver has two entries", and now names a controller package
  and a driver package that share an ID and a key. A section per role would tie both roles to one version digest. The
  user turned down a section per role, and a role taken from where the package is launched. Reworded two M2 checks.
- 2026-11-26: Added "The user binds a script driver's interpreter", the user's choice. "Script files are verified too"
  now names the interpreter's command, not its path. ADR-14 C2 was amended to say the interpreter is the one the user
  chose. The user turned down an absolute path in the descriptor, which no author can write for a pyenv or virtual
  environment Python, and a path from the declaration, which breaks C2.
- 2026-11-26: Added "Python's own file names can be packaged". A leading `_` is allowed, and a descriptor may list
  folder names to skip. Turned down copying only listed files, which would let a forgotten module fall through to the
  interpreter's search path unseen. (autonomous, addition)
- 2026-11-26: Added "A package may declare its starting folder as a read scope". Approvals store the resolved folder,
  and a new folder asks once. Turned down remembering the declared form, which a later layout request could aim at `/`
  with no review, and a per-run ask for undeclared folders, which reverses "A verified driver declares the access it
  needs". It depends on approvals holding more than 32 folders. The policy reader refused that, and moved the whole
  file aside. Fixed in "Keep a policy file whose merged read scope passes 32 folders". (autonomous, addition)
- 2026-11-26: Amended "Version skew" for the policy store. Format 2 carries a kind on every entry, and is written only
  when an entry is not a controller package entry. It said before that an older build "moves the file aside, for an
  unknown selector". Moving it aside lost every approval in the newer build after a run of new, old, and new builds.
  Turned down keeping format 1, and always writing format 2. (autonomous)
- 2026-11-26: Review pass 2, a re-check, NOT CONVERGED on one defect. Amended "The user binds a script driver's
  interpreter": it said "uniterm keeps the pick by package ID", and now keys it by ID, interpreter command, and signing
  key. IDs are not unique, so an unrelated package with the same ID, or a version that changed its command, ran under
  another binding with no prompt. "Script files are verified too" now applies the key list to native driver packages
  too. Routed checks to M1, M2, and M3. (autonomous, addition)
- 2026-11-26: Review pass 3, a re-check, CONVERGED. Corrected the binding's rationale, which said the new key closes
  both cases for every package. It closes the shared-ID case only for signed packages. Routed checks to M1 and M3.
- 2026-11-26: Review gate: kept all. The user kept the Python file-name rule for every package, the starting-folder
  read scope, the environment-key list for native driver packages, and the binding key of ID, command, and signing
  key. The earlier autonomous decisions on declaration sources, the layout path, the launch, the run binding, and
  version skew had no finding standing against them, and were kept.
- 2026-11-26: No decision from this review earns an ADR. The descriptor's role, the interpreter binding, the skipped
  folders, and the starting-folder scope each shape one component. ADR-14 C2 already states the interpreter rule, and
  ADR-18 covers the policy store's skew.
- 2026-11-26: Accepted, the user's choice, after the review gate. UTERM-004 gains its "Superseded in part by
  UTERM-066" markers, per Impacts.
- 2026-11-26: Amended the policy store bullet of "Version skew" for UTERM-067, which puts every approval in one store
  at a format above 2, with a kind on every entry. It ended before with: "UTERM-067 changes this under ADR-18." The
  in-flight risk said UTERM-067 is a draft. It is now accepted.
- 2026-11-26: Scheduled as UTERM-066 M1 and UTERM-066 M2-M3 in queue.md.
- 2026-11-27: Amended four places for UTERM-067 M2, which makes the policy file format 3 with every approval in
  `policy.json`. The UTERM-004 impact said: "The policy file gains format 2, per "Version skew"." M2's check said: "A
  policy file holding any entry that is not a controller package entry is written at format 2, with a kind on every
  entry. One holding only controller package entries is written at format 1. A build in use today leaves a format 2
  file untouched, and a run of new, old, and new builds keeps every approval." The older-build risk said a driver
  approval puts the file at format 2. The format 2 now belongs to UTERM-063, and no entry is written without a kind. The "Version skew" bullet on the
  policy store said before: "format 1 means every entry is a controller package entry, and no entry carries a kind.
  Format 2 requires a kind on every entry. A newer build writes format 2 whenever any entry is not a controller
  package entry, and format 1 otherwise. A build in use today then leaves a format 2 file untouched and trusts nothing
  from it, so a run of new, old, and new builds loses no approval. A newer build reads today's format 1 file unchanged.
  Once UTERM-067 lands, the store moves to a format above 2." (run best guess)

## References

- ADR-03: restored state never runs a program unasked
- ADR-06: description and layout versioning
- ADR-14: a controller controls what it opened, within authenticated identity and explicit scope
- ADR-18: stored data a build cannot read is kept, and never acted on (proposed)
- UTERM-004, "Verified artifact and run binding"
