# UTERM-023: Controller Runs with SIP Off

**Status:** accepted
**Created:** 2026-11-15
**Updated:** 2026-11-27

## Dependencies

- UTERM-003, for the bundle's `uniterm` command
- UTERM-004, for the code-hash match that admits a controller run
- UTERM-021, for the declared script-file runs the same match admits

## Impacts

- UTERM-004 — "Verified artifact and run binding": its loader-variable bullet says dyld removes every `DYLD_` variable
  before the command's code runs. That holds only while System Integrity Protection is on. The same bullet says a
  command built without the hardened runtime refuses a run while a `DYLD_` variable is set. "What uniterm does while
  SIP is off" supersedes that sentence in part.
- UTERM-021 — declared script files: a declared run started with a `DYLD_` variable set now starts clean instead of
  carrying the variable's library.

## Summary

Decide what uniterm does when it runs on a Mac with System Integrity Protection off. The kernel then leaves `DYLD_`
variables on the hardened `uniterm` command. A library named by `DYLD_INSERT_LIBRARIES` loads into a run that the app
will admit.

## Motivation

The app trusts a controller run only when the caller is the bundle's own command, matched by its code hash. That match
says nothing about code dyld loaded into the command first. With SIP on, the hardened runtime makes the kernel strip
the variables, so nothing loads.

GitHub's macOS runners have SIP off. On the first CI run of the PR that added the hardened command, GuardMalloc loaded
into the command. Three tests caught it. The signature checks passed in the same run, so the command is signed as
intended. The injection is the platform's behavior.

CI now skips the injection probes when SIP is off. That keeps CI green. It changes nothing in the product. A user who
turns SIP off still gets a trust boundary that no longer holds, and nothing says so.

The 2026-11-27 review traced how far that last claim holds. A malicious process of the same user gains nothing new
with SIP off. UTERM-004 and ADR-14 already place such a process outside what uniterm defends against. With SIP on, it
can already write the remembered-approval file, which is a plain file the user owns. What SIP off does break is the
guard against ordinary loader variables, such as a debugging library in the user's shell or a variable an IDE set.
The command refuses a controller run while one is set. A declared script file, an undeclared script, and `uniterm ask`
have no such check. On a Mac with SIP off, each of those sessions is admitted with the library loaded, and a declared
file keeps its remembered approval. The texts that say dyld always drops the variables are false on that Mac.

## Design Decisions (Settled)

### What uniterm does while SIP is off

The question was whether to change anything. The candidates were (a) treat SIP-off as outside the threat model and
change only the documents, (b) refuse controller runs while SIP is off, (c) warn on the review panel and in the
Controllers window while SIP is off, and (d) check at admission that the command loaded only expected images. The
review added three more: no change at all, one refusal before every admitted session, and the decision below.

Decision: the `uniterm` command starts clean, on every Mac. When its process starts, before it parses arguments or
reads any input, a command that finds a `DYLD_` key in its real process environment execs its own executable once,
with every `DYLD_` key removed. The run then proceeds as it would on a Mac with SIP on, unless library validation has
already killed the command over the library. A `DYLD_` key still present after that one re-exec refuses the run with
the key named. So does a re-exec that fails. Amended 2026-11-27; see Decision Log.

- The scrub runs first in each executable's `main`, for every mode of the command. That covers every session the app
  admits by the command's identity: controller runs from a package or a native entry, declared script files,
  undeclared scripts, `uniterm ask`, and REPL panes. It also covers modes that open no session, such as `--help`. One
  place at entry means a new mode or session kind cannot miss it, as three of four session paths missed the per-command
  check. Running before any input is read means the re-exec never loses a form or a script that arrived on a pipe.
- No library entry point re-execs. A test that calls the command's code in-process never execs the test runner.
- Nothing reads SIP state. The scrub keys on the variable being present, which is the effect that matters. It works
  the same under custom SIP configurations.
- The two controller paths change from refusing with status 64 to proceeding clean. A command built without the
  hardened runtime, such as the package tests' helper, changes the same way on every Mac.
- A malicious process of the same user stays outside the threat model, as UTERM-004 and ADR-14 state. A library that
  hooks the exec, or hides its variable, is that case. No product text claims otherwise.
- The documents say which mechanism holds where. With SIP on, dyld drops the variables before the command runs. With
  SIP off, the command drops them by re-exec before it does anything else. With SIP off, a library's initializers may
  already have run once in the discarded image. If library validation kills the command over a non-Apple library, that
  happens before `main`, and the documents say so once M1 has recorded the result.

Rationale: SIP off gives a malicious same-user process no authority it lacks with SIP on, so refusing or warning on
SIP state guards nothing the design claims. The real failure is that an ordinary loader variable reaches an admitted
run on three of four session paths. Starting clean restores the stated contract that "loader injection cannot select
substitute dependencies" on every path and every Mac. It gives the same behavior on a Mac with SIP off as on one with
SIP on, so a harmless variable in a shell file blocks nothing, unless library validation already kills the command. A
uniform refusal protects equally but refuses, on a Mac with SIP off, runs that a Mac with SIP on allows. Refusing
while SIP is off blocks every developer with SIP off. A warning on SIP state misses a declared file with a remembered
approval, which opens no review. An image-list report is the peer's own description of itself. Changing only the
documents withdraws a contract the code can keep.

Leaves undone: a library that hooks the exec or hides itself is admitted, which is the disclaimed same-user case. An
ambient library's initializers run once in the discarded image. A variable set on purpose to debug a script is
ignored silently, as it is with SIP on. A script's subprocesses stop inheriting the user's `DYLD_` variables on a Mac
with SIP off, as they already do on one with SIP on. Whether library validation kills the command over a non-Apple
library on a Mac with SIP off is unchecked. If it does, such a run fails before `main` under every candidate.

Converged in 2 critic passes. The critic proposed the re-exec in pass 1, and ranked it first in pass 2 with the scrub
at one place. The coherence review moved that place to process entry, since the shared session opener runs after
`uniterm ask` reads its form from standard input.

**Decided by:** proposal-reviewer (autonomous), 2026-11-27

### How the app reads SIP state

Original question: how the app reads SIP state. `csrutil status` needs a process launch. A syscall or a framework call
may be cheaper. This mattered only for (b) and (c).

Decision: the app does not read SIP state. "What uniterm does while SIP is off" keys on the variable, not on SIP. The
tests need no SIP reader either. Their assertions read the environment of the image that runs, which holds no `DYLD_`
key with SIP on or off. The test helper that runs `csrutil status` goes away with the skips. On a Mac with SIP on, the
shipped command's signature checks are the proof: it carries the hardened runtime, and no entitlement that lets dyld
variables in. That dyld then runs no initializer at all is the platform's guarantee.

**Decided by:** proposal-reviewer (autonomous), 2026-11-27

## Design Decisions (Open)

None.

## Risks

- **A malicious process of the same user loads its own code into the command on a Mac with SIP off** — likelihood:
  low, impact: high. Accepted: UTERM-004 and ADR-14 place same-user processes outside what uniterm defends against.
  Such a process can already write the remembered-approval file with SIP on, so SIP off adds no authority. The
  corrected documents say what SIP off exposes.
- **The re-exec loops, or its marker leaks into a script or a child process** — likelihood: low, impact: medium.
  Mitigation: one re-exec only, then a refusal that names the key. M1 checks that the marker never reaches a script or
  a child.
- **The re-exec changes the process's exec generation and breaks a binding the app compares** — likelihood: low,
  impact: medium. Mitigation: the scrub runs at process entry, before the command connects, so every binding the app
  records at connect sees the clean image. A REPL pane binds by process ancestry and the terminal's session
  generation, and an exec keeps the process ID and its parents. M1 checks the REPL pane, which the app launches with
  its own environment.
- **A user who sets a `DYLD_` variable on purpose to debug a script finds it ignored** — likelihood: medium, impact:
  low. Accepted: a Mac with SIP on already ignores it, and the documents say so.
- **Library validation behaves differently than the documents assume** — likelihood: medium, impact: low. The
  evidence does not settle the likelihood, so it takes the higher rating. Mitigation: M1's first check records how the
  shipped command treats a non-Apple library on a SIP-off runner, and the documents state that result.

## Milestones

### M1: The command starts clean

**Status:** NOT STARTED

- The shipped command runs on a SIP-off CI runner with `DYLD_INSERT_LIBRARIES` naming an ad hoc signed test library.
  The outcome, loaded or killed by library validation, is recorded in the As built block
- The scrub is one function, called first from the `main` of each executable that ships the command, the bundle's
  command and the package tests' helper, before argument parsing or any read of input. No library entry point
  re-execs
- A command that finds a `DYLD_` key in its real process environment re-execs itself once with every `DYLD_` key
  removed. A `DYLD_` key still present after that one re-exec refuses the run with the key named, and nothing loops.
  A re-exec that fails refuses the run with the key and the error named, and never proceeds with the key set
- The re-exec's marker never reaches a script, a native entry, or any child process
- A Janet package run, a native entry run, a declared file run, an undeclared run, `uniterm ask`, and a REPL pane,
  each started with a `DYLD_` variable set, proceed, and the running image's environment holds no `DYLD_` key. This
  holds with SIP on and with SIP off. `gen-form | uniterm ask` and a script given on a pipe still get their input. A
  REPL pane started from an app whose environment holds a `DYLD_` key still binds to its pane
- The three loader probes assert on the running image's environment, such as the native fixture's `loader: none`
  line, not on the GuardMalloc banner. They run on SIP-off CI runners with no skip. The shipped-command probe runs a
  mode whose output shows its environment in a release build, not `--help`
- The shipped-command probe keeps its assertions that the command carries the hardened runtime and no entitlement
  that lets dyld variables in. On a Mac with SIP on, those are the proof that dyld drops the variables
- The command's refusal over a `DYLD_` key in its environment parameter is removed, and its unit tests are rewritten
  for the clean start
- The test helper that runs `csrutil status` is removed
- Test spawn helpers that pass on the test process's environment drop its `DYLD_` keys, where a test relies on their
  absence. In-process tests that inject `DYLD_` keys through the environment parameter are rewritten
- Every text that says dyld always drops the variables says which mechanism drops them on which Macs: the command's
  doc comments, the identity check's doc comment, the probes' doc comments, and the comment in
  `scripts/check-sandbox-off.sh`
- UTERM-004's sentences that say dyld removes every `DYLD_` variable carry a Correction of fact that says they hold
  only with SIP on
- UTERM-004 marks its sentence on the helper's refusal "Superseded in part by UTERM-023; see Decision Log", with the
  Decision Log entry

## Decision Log

- 2026-11-15: Filed from a triaged bug. The bug records the CI evidence. It is linked from the bug file.
- 2026-11-27: Review start: 1 milestone, 0 settled decisions, 2 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; autonomous review of the open question, from the commit "Open UTERM-023 for controller
  runs on a Mac with SIP off".
- 2026-11-27 (autonomous): Premise traced. A malicious same-user process gains nothing new with SIP off: UTERM-004 and
  ADR-14 disclaim it, and it can already write the remembered-approval file. Ordinary loader variables do reach admitted
  declared-file, undeclared, and `uniterm ask` sessions on a Mac with SIP off, since only the two controller paths check
  for them. The Motivation now says so. The trace did not check whether library validation blocks a non-Apple library
  with SIP off.
- 2026-11-27 (autonomous): Corrected the Impacts line on ADR-10 and the claim that ADR-10 places SIP-off outside the
  threat model. ADR-10 says nothing about dyld, the hardened runtime, or SIP. The same-user limitation is in UTERM-004
  and ADR-14. ADR-10 left Impacts and References, and ADR-14 joined References.
- 2026-11-27 (autonomous, addition): Every session the app admits by the command's identity starts clean. A command
  that finds a `DYLD_` key re-execs itself once without it, at one place every such session opener passes through.
  The declared-file, undeclared, and `uniterm ask` paths are the addition, since the title and the first Motivation
  paragraphs name controller runs. Converged in 2 critic passes.
- 2026-11-27 (autonomous): The app does not read SIP state. The settled behavior keys on the variable.
- 2026-11-27 (autonomous): Replaced M1, which held the design decision, with the milestone that builds it.
- 2026-11-27 (autonomous, addition): Coherence review. Moved the scrub from "one place every identity-admitted session
  opener passes through" to process entry, for every mode. The only opener every session shares runs after `uniterm
  ask` reads its form from standard input, so a re-exec there would lose the form. The decision text before said
  "Before any such session opens" and listed four session kinds. Process entry also covers REPL panes and modes that
  open no session, which is the addition. Routed to M1: no in-process re-exec, a failed re-exec refuses, input on a
  pipe survives, and every text that claims dyld always drops the variables.
- 2026-11-27 (autonomous): Coherence review. Corrected the mitigation of the exec-generation risk: a REPL binds by
  ancestry and session generation, which an exec keeps. Kept the signature checks as the proof for Macs with SIP on.
- 2026-11-27 (autonomous): Risk review. The first risk's mitigation depended on the candidate, so it now records an
  acceptance: same-user processes are outside the threat model, and SIP off adds them no authority. Removed the risk
  that a SIP check misreads state, since nothing reads SIP state. Added the re-exec loop and marker risk, mitigated by
  one re-exec then a refusal. Added the exec-generation risk, mitigated by scrubbing before connect. Accepted the risk
  that a deliberate debugging variable is ignored, since a Mac with SIP on already ignores it. Rated the
  library-validation risk at the higher likelihood, since no evidence settles it, and mitigated it with M1's first
  check.
- 2026-11-27 (autonomous): Coherence re-check converged. Routed to M1: the shipped-command probe keeps its signature
  assertions and runs a mode that shows its environment, the old refusal and its tests go, and UTERM-004's dyld
  sentences get a Correction of fact. Dropped a gap on UTERM-066: the app, not the command, spawns a verified driver's
  native entry with an environment the app builds, and it refuses a `DYLD_` key the package declares. That path never
  runs the command, and leans on no sentence this proposal supersedes.
- 2026-11-27 (autonomous): ADR candidate (cuts across the system): code that uniterm trusts by its verified identity
  loads nothing that the caller's environment names. Declined: it would widen ADR-14 C2, whose loader-hook clause
  covers shared interpreters, to every trusted run. That is a change to ADR-14, not a new ADR, and this design does
  not conflict with ADR-14 as written.
- 2026-11-27: Review gate: kept all. The clean start covers every mode of the command, the ADR-10 update stays
  dropped, and UTERM-004's loader-variable sentence gets a correction of fact.
- 2026-11-27: Accepted. No decision earns an ADR.

## References

- ADR-14: a controller controls what it opened, within authenticated identity and explicit scope
- UTERM-004: control and trust
- UTERM-021: declared script permissions
- Bug: `spec/bugs/20261115-loader-variables-reach-hardened-command-with-sip-off.md`
