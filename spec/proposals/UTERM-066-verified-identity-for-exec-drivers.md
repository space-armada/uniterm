# UTERM-066: Verified Identity for Exec Drivers

**Status:** draft
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- UTERM-004: exec drivers, their launch, and controller verification ("Verified artifact and run binding")
- UTERM-063: permission descriptors and the layout-request API stay at version 0, so the new declaration field lands
  in place
- UTERM-028, UTERM-055, UTERM-065: M2 remembers the command, capture, and read-scope powers they define. Each part of M2
  waits on its proposal's power being built

## Impacts

- UTERM-004 — "Exec launch context" and "Saved layouts": a declaration may name a package, and the layout saves it.
  "Verified artifact and run binding": the app, not the `uniterm` command, spawns a verified native entry for a
  driver, so the app must refuse `DYLD_` variables itself. UTERM-004 is implemented, so its text stays, and it gains
  "Superseded in part by UTERM-066" markers when this proposal is accepted.
- UTERM-028 — "How a driver gets the power": "Nothing is remembered across runs, since a driver has no verified
  identity" holds only for a driver with no verified identity.
- UTERM-055 — "Which grant and targets an exec driver captures under": a verified driver may keep a remembered
  approval for capture.
- UTERM-065 — "How long the grant lasts": its revisit hook names this proposal. A verified driver may keep a remembered
  read scope. "The driver asks at run time": a verified driver's request for directories its package did not declare
  is denied, per "A verified driver declares the access it needs".
- UTERM-048 — "A plain script or a driver is never labeled verified": a verified driver is labeled with its identity.
- Driver clipboard and browser grants (UTERM-004, UTERM-019): a verified driver may keep remembered approvals for them.

## ADR Deviations

- ADR-14 P9, no carve-out: "Claimed names, paths, digests, and the identity of a shared interpreter are insufficient
  proof of script identity." "Script files are verified too" verifies a script an interpreter driver names in its argv
  by its digest, through a snapshot uniterm makes. The interpreter does not load it through a verifying loader.
  UTERM-004 asks for "an equally verifiable loader" before another interpreter's scripts receive persistent trust. The
  descriptor fixes the interpreter, its flags, and the script, and hook keys are refused. Any interpreter the user has
  may run a driver. What a remembered approval still trusts without checking is the code the script imports at run
  time, the interpreter's install, and its startup files, such as Python's `.pth` files and `sitecustomize`, per "Trust
  covers what uniterm verified, and says so". The user chose this on 2026-11-26, after
  imports, the interpreter binary, flags, and hook keys were named. The startup files were found after that choice.
  This proposal asks the user to amend ADR-14 with C2, per "ADR-14 gains a carve-out for verified scripts". Once
  that is approved, this entry becomes "ADR-14 P9 under C2".

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

Decision: a script driver's descriptor fixes its whole command line. It names the interpreter, the interpreter's
flags, and the script, which is a file the descriptor lists. uniterm snapshots and verifies the script with the package,
and the interpreter runs the snapshot copy. The declaration supplies only the arguments after the script. A package
declaration that names an environment key the interpreter reads as a hook, such as `PYTHONSTARTUP`, `PYTHONPATH`, or
`NODE_OPTIONS`, is refused. Amended 2026-11-26; see Decision Log.

**Decided by:** user, 2026-11-26

Rationale: most drivers are scripts. Leaving them out would keep every script driver asking each run. Fixing the
command line in the signed descriptor closes interpreter flags and scripts outside the signature. Refusing hook keys
closes the environment. What trust says about the interpreter is settled in "Trust covers what uniterm verified, and
says so". Imports stay unverified, which is the deviation from ADR-14 P9 recorded above.

### Any interpreter the user has may run a driver

Decision: a script driver may name any interpreter the user has, including a Homebrew install, a local build, or a
virtual environment. uniterm adds no limit on which interpreter a driver uses, on how it is installed, or on how the
user has set it up, and no such limit decides whether a driver can keep a remembered approval.

**Decided by:** user, 2026-11-26

Rationale: uniterm does not control how a user installs or uses interpreters, and may not add artificial limits on
them.

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
selector matches only runs of its own kind. A package trusted both as a controller and as a driver has two entries,
one per role, each with its own powers. Revoking one leaves the other.

**Decided by:** user, 2026-11-26

Rationale: ADR-14 P8 says one granted power never silently grants another. Trusting a package to read the clipboard as
a driver in a pane must not let it do so as a controller started from a shell. The code already keeps script-file and
package approvals apart for the same reason. The window can still group a package's entries, so it reads as one
program with two roles.

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
API, like any exec declaration. A controller's `host-launch` scope matches a package declaration by the package's
identity: its ID with its version, or its ID with its signing key. A `host-launch` scope that names an executable path
never covers a package.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: a declaration only places a driver in a pane. Nothing runs until the user presses Run, or a `host-launch`
grant covers the launch, so a program declaring a package gains nothing by itself. Matching by identity follows the
trust boundary of "A verified driver declares the access it needs": the grant names the package it covers, not a path
anything can replace. UTERM-004 meant a host launch to name packaged entries.

### A layout saves the package's absolute path

Decision: the layout saves a package declaration as the package folder's absolute path, beside the arguments after the
script, the directory, and the environment key names. A package that has moved fails to launch, and the pane says
where it looked. The layout envelope moves to version 4.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: verification and the launch prompt run on every launch, so the path is all a launch needs. A bookmark would
add a second way to find the package, and the prompt would then have to say where it found it. uniterm is pre-v1, so
the envelope bump costs nothing, and ADR-06 keeps a newer file aside in an older build.

### The launch is never remembered

Decision: a verified driver's launch asks as today, through UTERM-004's launch approval or a `host-launch` grant.
Remembered approvals cover the driver's powers, never its launch.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: the launch prompt is the only place the user sees the arguments a driver starts with. A pane a program laid
out could otherwise start a trusted package with arguments the user never saw, and a relay driver such as `ssh host`
would reach whatever host the arguments name. A remembered launch would also be a new remembered power, beyond the
per-run powers this proposal covers.

### A run is bound to the process uniterm spawned, until it execs

Decision: the app spawns the snapshot's entry itself, and binds the run to the process it spawned, that process's exec
generation, and the snapshot it made. Every use of a remembered power checks the binding. When the process execs
another program, its verified identity ends, and its remembered powers with it. Its channel stays, as for a driver with
no package. A package declaration that names a `DYLD_` key is refused, so no library is injected at spawn.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: the app already holds the driver's pipe, so there is no peer to authenticate, and a second launcher would
add nothing. Without the exec check, a verified driver could exec any program and keep the powers trusted for the
package. UTERM-004 already ends a controller's live binding when its executable is replaced. Watching the process's
exec generation reads nothing of its code, so it keeps to "Trust covers what uniterm verified, and says so".

### Version skew

Decision: uniterm is pre-v1, so each contract may break, and the behavior is stated rather than made tolerant.

- The policy store: an older build that meets a driver entry keeps no trust at all, for an unknown kind, or moves the
  file aside, for an unknown selector. UTERM-067 changes this under ADR-18.
- The layout file: an older build keeps a version 4 file aside, per ADR-06.
- The descriptor, which gains driver kinds, an interpreter entry kind, and a fixed command line: an older build refuses
  a new package by name, through strict parsing. A newer build reads an old package unchanged.
- The layout-request API's package field: an older app refuses a new caller by name, which UTERM-063 allows at version
  0.

**Decided by:** new-proposal (autonomous), 2026-11-26

Rationale: the user accepts breaking changes before v1. Each failure is a refusal by name or a kept file, never a
silent grant, so none fails open.

### ADR-14 gains a carve-out for verified scripts

Decision: this proposal asks the user to amend ADR-14 with a carve-out to P9. The amendment applies once the user
approves its text. Until then, the script decisions stand as the deviation recorded under ADR Deviations.

> **C2** (relaxes P9): A script run by a shared interpreter may hold a remembered approval when uniterm itself
> snapshots and verifies the script and every file its package declares, and starts the interpreter with a command line
> those verified files fix. The proof of identity is uniterm's own verification, not a name, path, or digest the script
> or its runner claims. The approval covers only the verified files and the access they declare. The interpreter, its
> install, and whatever the script loads beyond its package are outside it, and the user is told so. Verifying files
> cannot isolate a program from the system it runs on, so the approval states its boundary rather than claim one it
> cannot hold.

**Decided by:** new-proposal (autonomous), 2026-11-26

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
  command line, and hook keys are refused, per "Script files are verified too". Accepted for the rest: the interpreter,
  its startup files, and system libraries are outside what uniterm verifies, and the review text says so, per "Trust
  covers what uniterm verified, and says so".
- **A verified script driver imports unverified code** — likelihood: high, impact: medium. An interpreter loads modules
  from its own search paths. Mitigation: the review text says imports are not verified, and "Trust this version" binds
  only the packaged files. Accepted pending the ADR-14 amendment above.
- **An older build loses every controller approval** — likelihood: medium, impact: low. A driver approval in
  `policy.json` stops or moves aside every controller approval in an older build. Accepted: uniterm is pre-v1, and the
  user accepts breaking changes until then.
- **A remote party behind a trusted driver** — likelihood: low, impact: medium. "Trust this version" of a packaged
  ssh-like driver remembers powers for whatever host its argv names. The approval binds the local code, not the remote
  party. Mitigation: "The launch is never remembered" keeps the arguments in front of the user.
- **A same-user process edits the snapshot** — likelihood: low, impact: medium. UTERM-004 notes that read-only files
  are not immutable against a malicious process of the same user. Accepted: the same holds for controllers today.
- **The design depends on proposals still in flight** — likelihood: medium, impact: medium. UTERM-028 and UTERM-055 are
  not started, UTERM-065 is a draft, and UTERM-063 changes permission editions underneath. Mitigation: M2's parts wait
  on each power, per Dependencies.
- **A layout's package declaration is stored data** — likelihood: medium, impact: medium. Every later build reads it.
  Mitigation: ADR-06's versioned envelope, and "A layout saves the package's absolute path".

## Milestones

### M1: Package declarations and a verified spawn

**Status:** NOT STARTED

- A declaration that names a package snapshots it, verifies the copy, and spawns the snapshot's entry
- A package whose descriptor, digests, signature, or load commands fail is refused, and nothing runs
- A package declaration that names a `DYLD_` environment key is refused before anything runs
- A declaration with a bare executable launches as today, with no verified identity
- A driver package declares its powers in its descriptor, which knows the driver's kinds. A driver package that
  declares a controller-only kind, such as `pane-control` or `host-launch`, is refused
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

- The panel offers "Trust this version" and "Trust this identity" for a verified driver's clipboard, browser, command,
  capture, and read-scope requests
- A remembered approval covers the next run of the same version or identity with no prompt
- A changed package asks again under "Trust this version", and a package signed by another key asks again under "Trust
  this identity"
- A driver with no verified identity is never offered a remembered approval
- A driver approval never covers a controller run of the same package, and a controller approval never covers a driver
  run
- A package trusted in both roles shows two entries, and revoking one leaves the other
- Revoking a remembered approval removes it from the store, ends a live run's use of it, and stops its queued work
- Each use of a remembered power is checked at the effect, against the live policy

### M3: Verified script drivers

**Status:** NOT STARTED

- A driver whose entry is an interpreter runs the snapshot copy of its packaged script
- The interpreter, its flags, and the script come from the descriptor. A declaration can add arguments only after the
  script
- Each interpreter kind the descriptor may name has a listed set of refused hook keys, tested per interpreter. It
  includes at least `PYTHONSTARTUP`, `PYTHONPATH`, `PYTHONHOME`, `PYTHONUSERBASE`, `PYTHONINSPECT`, `NODE_OPTIONS`,
  `NODE_PATH`, `RUBYOPT`, `RUBYLIB`, `PERL5OPT`, `PERL5LIB`, `PERLLIB`, `BASH_ENV`, `ENV`, and keys starting with
  `BASH_FUNC_`. A package declaration that names one is refused before anything runs
- A Homebrew interpreter, a locally built one, and one in a virtual environment each run a verified script driver and
  can keep a remembered approval
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
- 2026-11-26: Recorded both reasons one entry per role beats one entry with a list of roles, at the user's request:
  the roles carry different powers, and ADR-18 P4 keeps an unknown role a whole skipped entry.

## References

- ADR-03: restored state never runs a program unasked
- ADR-06: description and layout versioning
- ADR-14: a controller controls what it opened, within authenticated identity and explicit scope
- ADR-18: stored data a build cannot read is kept, and never acted on (proposed)
- UTERM-004, "Verified artifact and run binding"
