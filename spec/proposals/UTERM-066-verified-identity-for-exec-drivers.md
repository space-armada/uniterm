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
  read scope.
- UTERM-048 — "A plain script or a driver is never labeled verified": a verified driver is labeled with its identity.
- Driver clipboard and browser grants (UTERM-004, UTERM-019): a verified driver may keep remembered approvals for them.

## ADR Deviations

- ADR-14 P9, no carve-out: "Claimed names, paths, digests, and the identity of a shared interpreter are insufficient
  proof of script identity." "Script files are verified too" verifies a script an interpreter driver names in its argv
  by its digest, through a snapshot uniterm makes. The interpreter does not load it through a verifying loader.
  UTERM-004 asks for "an equally verifiable loader" before another interpreter's scripts receive persistent trust. The
  descriptor fixes the interpreter, its flags, and the script, and hook keys are refused. What a remembered approval
  still trusts without checking is the code the script imports at run time, and the interpreter binary as far as
  "Which interpreter an entry may name" leaves it open. It also trusts the interpreter's own startup files, unless an
  isolating flag turns them off. Python runs `.pth` files and `sitecustomize` from the user's site folder, which any
  same-user process can write, and which a declared `HOME` can move. The user chose this on 2026-11-26, after imports,
  the interpreter binary, flags, and hook keys were named. The startup files were found after that choice. This
  proposal asks the user to amend ADR-14 P9 before it is accepted.

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
controllers. Hashing only the executable would leave the libraries and data it loads unverified.

### Script files are verified too

Decision: a script driver's descriptor fixes its whole command line. It names the interpreter, the interpreter's
flags, and the script, which is a file the descriptor lists. uniterm snapshots and verifies the script with the package,
and the interpreter runs the snapshot copy. The declaration supplies only the arguments after the script. A package
declaration that names an environment key the interpreter reads as a hook, such as `PYTHONSTARTUP`, `PYTHONPATH`, or
`NODE_OPTIONS`, is refused. Amended 2026-11-26; see Decision Log.

**Decided by:** user, 2026-11-26
**Pending override:** also require, for each interpreter kind, the flag that isolates it from user startup files, such
as Python's `-I`, and refuse a declared `HOME`. Without them, Python's `.pth` files and `sitecustomize` in the user's
site folder run before the script under remembered approvals, and a declared `HOME` can point that folder anywhere.
Recommended by new-proposal (critique).

Rationale: most drivers are scripts. Leaving them out would keep every script driver asking each run. Fixing the
command line in the signed descriptor closes interpreter flags and scripts outside the signature. Refusing hook keys
closes the environment. The interpreter binary is constrained by "Which interpreter an entry may name". Imports stay
unverified, which is the deviation from ADR-14 P9 recorded above.

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
package approvals apart for the same reason. One entry per role keeps each approval about one role, and the window can
still group a package's entries together.

## Design Decisions (Open)

### Which interpreter an entry may name

A packaged entry must be a file inside the package, and its load commands must name only packaged files or system
paths. A Homebrew `python3` links `/opt/homebrew/...`, so it cannot be packaged. An interpreter entry needs a new entry
kind that names an outside path. A same-user process can replace a file the user owns.

- A. Only an interpreter on the sealed system volume, or on a path root-owned all the way up.
- B. The descriptor pins the interpreter's digest. Every interpreter upgrade asks again.
- C. The interpreter is packaged. This fails the load check for most interpreters in practice.

### What a driver package declares in `permissions`

The descriptor requires `permissions`. It knows no command or capture kind, and accepts controller-only kinds such as
`pane-control` and `host-launch`. UTERM-004 refuses undeclared effects even under trusted identity.

- A. The driver declares its powers. It gets a review at start, and undeclared requests are refused, as for controllers.
- B. The driver declares none. Each request is remembered on its own row, and a non-empty `permissions` is refused for
  a driver.

### Where a package declaration can come from

A declaration comes from a layout file, the layout-request API used by scripts, controllers, and drivers, or the UI.
The layout-request API refuses unknown exec keys, so a new caller on an older app is refused by name. A controller's
`host-launch` scope names an absolute executable today.

- How a `host-launch` scope matches a package declaration: by the package's identity, or by its entry path
- Whether a program may declare a package at all, or only the user

### How a layout saves a package declaration

UTERM-004 saves argv, directory, and environment key names only. A package declaration needs the package's location.
An older build reads only those three fields and drops any other on its next save. Either option bumps the layout
envelope to version 4, and ADR-06 keeps a newer file aside in an older build.

- A. The layout saves the package folder's absolute path. A moved package fails to launch, with a message.
- B. The layout saves the path and a bookmark, as the viewers do for their sources. A moved package is found through
  the bookmark, and the pane says where.

### Whether the launch itself can be remembered

UTERM-004's launch approval asks once, or grants a pane's exact executable and directory for one launch of uniterm. A
verified driver could be launched without asking.

- A. No. The launch asks as today. Remembered approvals cover only the powers.
- B. "Trust this version" or "Trust this identity" also covers the launch, so a restored pane's Run starts a trusted
  driver with no prompt. That removes the only prompt that shows argv. A pane a controller laid out could start a
  trusted package with argv the user never saw.
- C. A remembered launch scoped like UTERM-004's reusable launch approval: the package identity, an allowed directory,
  and environment keys.

### The run binding when the app spawns the snapshot

A native controller's snapshot entry is started by the hardened `uniterm` command, whose dyld strips every `DYLD_`
variable. A driver is spawned by the app, with an environment built from the declaration, which may name
`DYLD_INSERT_LIBRARIES`.

- A. The app spawns the snapshot entry, and binds the run to the PID it spawned and the snapshot it made. A driver that
  execs another binary keeps its pipe, and would keep the remembered powers.
- B. A, plus: record the PID's exec generation at spawn and check it wherever a remembered power is used, and treat an
  exec as ending the identity. M1 refuses `DYLD_` keys under either option.
- C. The app hands the snapshot to a small launcher that verifies again and execs it. The app already holds the pipe,
  so no peer needs authenticating, and a second check races a same-user process the same way.

### Version skew

The proposal changes four contracts. Each needs its skew behavior settled.

- The policy store, shared across builds and across instances running at once. Today an older build that meets an
  entry of a kind it does not know keeps no trust at all, and a selector kind it does not know moves the whole file
  aside. uniterm is pre-v1, so this breakage is accepted for now. Whether the store should tolerate unknown entries
  before v1 is a question beyond this proposal, raised as an ADR candidate in the Decision Log.
- The layout file. An older build keeps a version 4 file aside, per "How a layout saves a package declaration".
- The descriptor, which gains an interpreter entry kind and a fixed command line. A new package on an old build is
  refused by strict parsing. An old package on a new build reads unchanged.
- The layout-request exec field. A new caller on an old app is refused by name, which UTERM-063 allows at version 0.

## Risks

- **An interpreter, argv, or environment substitution gets remembered powers** — likelihood: high, impact: high. A
  replaced interpreter, a flag such as `python3 -c`, or a hook such as `PYTHONSTARTUP` runs code no digest covers, under
  remembered approvals. Mitigation: the descriptor fixes the command line, and hook keys are refused, per "Script
  files are verified too". The interpreter binary waits on "Which interpreter an entry may name". This blocks
  acceptance until that question is settled.
- **A verified script driver imports unverified code** — likelihood: high, impact: medium. An interpreter loads modules
  from its own search paths. Mitigation: the review text says imports are not verified, and "Trust this version" binds
  only the packaged files. Accepted pending the ADR-14 amendment above.
- **An older build loses every controller approval** — likelihood: medium, impact: low. A driver approval in
  `policy.json` stops or moves aside every controller approval in an older build. Accepted: uniterm is pre-v1, and the
  user accepts breaking changes until then.
- **A remote party behind a trusted driver** — likelihood: low, impact: medium. "Trust this version" of a packaged
  ssh-like driver remembers powers for whatever host its argv names. The approval binds the local code, not the remote
  party. Mitigation: "Whether the launch itself can be remembered" keeps argv in front of the user under option A.
- **A same-user process edits the snapshot** — likelihood: low, impact: medium. UTERM-004 notes that read-only files
  are not immutable against a malicious process of the same user. Accepted: the same holds for controllers today.
- **The design depends on proposals still in flight** — likelihood: medium, impact: medium. UTERM-028 and UTERM-055 are
  not started, UTERM-065 is a draft, and UTERM-063 changes permission editions underneath. Mitigation: M2's parts wait
  on each power, per Dependencies.
- **A layout's package declaration is stored data** — likelihood: medium, impact: medium. Every later build reads it.
  Mitigation: ADR-06's versioned envelope, and "How a layout saves a package declaration".

## Milestones

### M1: Package declarations and a verified spawn

**Status:** NOT STARTED

- A declaration that names a package snapshots it, verifies the copy, and spawns the snapshot's entry
- A package whose descriptor, digests, signature, or load commands fail is refused, and nothing runs
- A package declaration that names a `DYLD_` environment key is refused before anything runs
- A declaration with a bare executable launches as today, with no verified identity
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
- An interpreter kind with no isolating flag is either allowed with its refused keys alone or not allowed, and the
  check says which for each kind
- A packaged multi-file script driver imports its packaged sibling modules under the flags the descriptor fixes
- An old build refuses a package with an interpreter entry by name
- A changed script asks again under "Trust this version"
- The review text names what stays unverified: imports, and the interpreter's startup files where no isolating flag
  turns them off

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
  stored data it cannot read. What it cannot read, it keeps unchanged and acts on nothing from. Undecided. Raised by
  the user, who asked whether to adopt it before v1.

## References

- ADR-03: restored state never runs a program unasked
- ADR-06: description and layout versioning
- ADR-14: a controller controls what it opened, within authenticated identity and explicit scope
- UTERM-004, "Verified artifact and run binding"
