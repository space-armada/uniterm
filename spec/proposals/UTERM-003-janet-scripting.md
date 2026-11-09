# UTERM-003: Janet Scripting and REPL

**Status:** accepted
**Created:** 2026-10-31
**Updated:** 2026-11-09

## Dependencies

- UTERM-001

## Impacts

- UTERM-002 — "Scope": scripts neither invoke nor register registry commands in this proposal, which answers the
  risk UTERM-002 left to UTERM-003. The palette never runs commands through the host API, per UTERM-002
- UTERM-004 — "Host API" and "Sandboxing": control levels limit what scripts may do to panes
- UTERM-004 — "How `uniterm run` reaches the app" and "REPL features": the listener records each peer's audit token
  and PID, which UTERM-004's caller identity should build on rather than add a second listener. A REPL's token binding
  is not a same-user defense, and UTERM-004 should not trust it as one

## Summary

uniterm embeds Janet. A small host API lets scripts list panes, open applets and tabs, and send content to applets.
Scripts run from the command line with `uniterm run file.janet`, or interactively in a REPL applet.

## Motivation

The write-up asks for a low-level, scriptable control layer beneath the command palette. A Lisp keeps that layer small
and easy to extend. Janet is already the chosen embedded Lisp for Swift hosts in the coding standards.

## Design Decisions (Settled)

### Janet is the embedded language

Janet is vendored from one tagged release and compiled into a helper executable that ships in the app bundle. It
follows the embedding rules in the coding standards: one owning thread, `janet_pcall` at every entry, rooted values,
and a sandbox. Amended 2026-11-02, see "Where scripts run" and the Decision Log.

### Host API

- The host API is a small, named set of functions in its own Janet module.
- The API has a version. Scripts can check it.
- Every host function validates its arguments. Bad input returns an error to the script. It never crashes the app.

A first set of functions:

- List windows, panes, and applets.
- Open a pane with a given applet.
- Open a tab in an applet that supports tabs.
- Send a document or data to an applet for display.
- Post a status bar message.

Rules for the first set:

- A pane or tab a script opens starts in the directory the call names. When the call names none, a pane opened beside
  another starts in the directory that pane reports through the applet contract, as a split from the UI does. The CLI's
  working directory never flows in implicitly.
- No host function in this proposal writes to a terminal's input. Sending to a terminal applet, or to a REPL applet,
  which hosts one, is refused with an error to the script.

### Invariants scripts rely on

Scripting is viable only if these hold. Every host function, and every later change to the host API, keeps them:

- A reference to a window, pane, or tab never resolves to a different one. A reference to one that is gone resolves to
  nothing.
- References are valid for one launch only. Nothing a script holds survives a relaunch.
- Every ID a script receives is an exact integer in a Janet number.
- A host function never crashes the app. Bad input returns an error to the script.
- A script can read the API version, and a change that breaks a script changes the version.

### Scope

Out of scope, for later proposals:

- Invoking or registering UTERM-002 registry commands from scripts. Every Janet-backed action would first have to
  settle how a script awaits an action, and how a script-registered command reports availability, without the main
  thread waiting, as UTERM-002's risks require.
- Granting capabilities to a REPL. See "Sandboxing".

### Two entry points

- `uniterm run file.janet` runs a script against a running uniterm.
- A REPL applet runs in a pane. It evaluates Janet against the same API.

### Sandboxing

Scripts are denied file, network, process, and FFI access unless their job needs it.

- A `uniterm run` script gets a capability only when the command line names it, such as `uniterm run --allow fs-read
  file.janet`, using Janet's own capability names. The user grants it at the moment they run the script.
- A REPL grants no capability in this proposal. Janet's sandbox cannot be widened once applied, so a REPL's grants are
  fixed when its helper starts. A way to grant a REPL more waits on UTERM-004.
- There is no CPU limit on a run or a REPL evaluation. The user stops either with Ctrl-C, and a script can no longer
  freeze the app, since the main thread never waits on a helper. The helper's watchdog thread carries out Ctrl-C and
  the app's stop request. Amended 2026-11-02, see the Decision Log.
- Memory is bounded per helper, per "Where scripts run".
- The helper holds no App Sandbox entitlement, for the reason in "Where scripts run". Janet's `sandbox` is applied
  before the first line of a script runs, with every capability denied unless the command line grants it. Amended
  2026-11-09; see Decision Log.

**Revisit:** when UTERM-004 settles control levels, decide how a REPL is granted capabilities.

### Where scripts run

Original question: one VM for the app, or one VM per script or REPL, and which thread owns each VM. AppKit work must
happen on the main thread.

Decision: one VM per script run and per REPL pane, each in its own process, separate from the app.

- Janet is never linked into the app process. Each VM lives in a helper process with one VM on the helper's main
  thread. The app spawns one helper per REPL pane. How a `uniterm run` process relates to a helper is settled under
  "How `uniterm run` reaches the app".
- A helper exits when its connection to the app closes, so no helper outlives the app.
- The helper is not in the App Sandbox. `uniterm run` is the user's own process. It reads the script by path, connects
  to a socket by path, and may be granted `--allow fs-read`. A REPL helper starts from a terminal. The terminal
  launch can pass only a working directory, an environment, and a program, and ADR-01 bars reaching past that
  protocol, so the helper connects by path too. Janet's sandbox, the memory
  cap, and process isolation bound the helper instead. The last bullet of ADR-10's Decision allows this. Amended
  2026-11-09; see Decision Log.
- Host API calls are messages from the helper to the app. The app runs each one on the main thread and replies.
- The main thread never waits on a helper. Any later Janet-backed action the app runs sends its message and returns.
- The helper's watchdog thread interrupts a running evaluation on Ctrl-C or on the app's stop request, and the VM keeps
  its state. The app kills a helper only when it stops answering or passes its memory bound.
- Memory is capped in two layers:
  - In the helper: `janetconf.h` routes Janet's allocator through a counting wrapper. An allocation that would pass the
    per-helper cap fails, and the helper exits with a memory-limit status and message. It does not try to recover,
    since Janet's out-of-memory path is not safe to unwind. This layer covers every helper, `uniterm run` included.
  - In the app: the app reads the footprint of each helper it spawned with `proc_pid_rusage`, and kills one that passes
    the cap by a margin. This catches memory the counting wrapper does not see. A `uniterm run` process is the user's
    own process, which the app did not start, so the app never kills it; the first layer bounds it.
  - A helper that ends for memory reports it: the REPL pane shows the message and offers a restart, and a run exits
    nonzero with the message on stderr.
  - The cap is 1 GiB per helper.
- An app-wide budget bounds the REPL helpers the app spawned, taken together. It is 4 GiB, or a quarter of physical
  memory when that is smaller. While their total footprint is over the budget, a new REPL does not start. The empty
  pane says why and offers a retry that only the user can run, and the history records one warning. A restored pane
  never retries on its own. A running REPL is never killed for the total. Since each helper is capped, the total
  overshoots the budget by at most one cap. `uniterm run` processes do not count, since each is the user's own and is
  capped. Amended 2026-11-06; see Decision Log.
- Neither size is a setting. The budget scales with the machine, and a setting waits until users need other values.
- Skew: the app and its helpers are two binaries in one bundle, and replacing the bundle on disk while uniterm runs
  pairs an old app with a new helper. Both sides exchange a protocol version when they connect. On a mismatch the
  connection is refused, and the user is told to relaunch uniterm. Neither side tries to speak the other's version.

Rationale: Janet has no heap limit. Its default out-of-memory handling exits the process, so in the app a script like
`(buffer/new 1e12)` would end every shell in every window without the quit confirmation. The embedding standard bounds
memory with a separate process when the runtime cannot. A process also contains a crash in Janet's C code, and a C call
the interrupt flag never reaches, such as a long `peg/match`. One VM per run or REPL keeps scripts from stalling or
corrupting each other. A thread per VM in the app keeps the main thread free, but it cannot bound memory or stop a VM
stuck in C. A shared VM adds one script stalling all others. A VM on the main thread breaks the risk mitigation that
keeps Janet off it. The rule that the main thread never waits holds in any design that lets scripts register
commands, since a run action waiting on a VM that waits on the main thread deadlocks.

Leaves undone: nothing. It costs a second executable target and an app-to-helper message protocol, which `uniterm run`
needs in some form anyway.

### API naming and shape

Original question: function names and namespaces, and how panes are identified: stable IDs, paths in the tree, or
both. ADR-02 rules out paths, so only stable IDs remain. Pane IDs are unique only within one window.

Decision: a window ID that is unique across launches, plus the pane ID. References are plain data.

- Each window gets an ID when it opens. Window IDs never repeat across launches, without persisted state, the same rule
  UTERM-002 set for tab IDs. A restored window gets a new ID. Every ID handed to a script fits in a Janet number
  exactly, so below 2^53.
- A pane reference is a struct, `{:window 3 :pane 7}`. A tab reference adds `:tab`. A reference to a closed pane, or
  one from an earlier launch, resolves to nothing. It never resolves to a different pane.
- Window, pane, and tab references share one lifetime: valid for this launch only.
- The API is one Janet module, `uniterm`, imported with `(import uniterm)`. Functions are kebab-case verb-noun names,
  such as `uniterm/list-panes`, `uniterm/open-pane`, `uniterm/open-tab`, `uniterm/send`, and `uniterm/post-status`,
  with `uniterm/api-version`.

Rationale: pane IDs are restored from the layout file, so a window counter that restarts at each launch would let a
reference kept in a shell script, such as `{:window 1 :pane 4}`, hit another window's pane 4 after a relaunch. That
breaks ADR-02's rationale. Persisting window IDs would make the window and pane parts of a reference outlive the tab
part, and needs an envelope schema bump per ADR-06 for a requirement nobody stated. App-global pane IDs still need a
window ID for "list windows" and opening a pane in a given window, and they renumber saved panes. Current-window-only
addressing contradicts the settled "list windows", and makes the key window an implicit target.

Leaves undone: nothing.

### How `uniterm run` reaches the app

Original question: a Unix domain socket owned by the running app, XPC, or running the script in the CLI process and
sending API calls to the app. The choice also shapes UTERM-004's trust model, since the app must know who is calling.

Decision: the CLI runs the script's VM in its own process, and connects to the app over a Unix domain socket.

- The `uniterm` command is the helper executable, run in its script mode. One Janet build and one app-to-helper
  protocol serve both entry points.
- The running app listens on a socket in a per-user directory that only the user can read. The app reads each peer's
  audit token and PID from the socket, for UTERM-004.
- The script's output, input, arguments, working directory, and exit status are the CLI process's own. Ctrl-C or a
  kill on the CLI stops the VM and closes its connection. Nothing is relayed through the app.
- REPL helpers connect to the same listener, per "REPL features".
- Each running instance listens at its own address, and passes that address to its REPL helpers. The first instance to
  start also claims the well-known per-user address, under a lock that tells a live owner from a stale socket.
  `uniterm run` connects to the well-known address. A second instance, such as one a UI test starts, never takes it
  over.
- Skew: the `uniterm` command on `PATH` is a symlink into the app bundle, never a copy, so it is always the bundle's
  helper and the version handshake in "Where scripts run" covers it. A command that is not the bundle's own is refused
  with a message that says to reinstall the command. M3 builds the way to install the symlink.

Rationale: the VM in the caller's process gives `uniterm run` normal process behavior with no relay, and `print`
behaves the same in a run and in the REPL. Handing the script to the app makes the app buffer or throttle unbounded
script output on its way to the CLI, needs a second protocol, and needs stdin, arguments, working directory, and
signals forwarded explicitly. Without that forwarding, the helper would inherit the app's directory and environment
silently. XPC from a CLI the app did not launch needs a launch agent and a Mach service, which users can turn off in
Login Items, and its code-signature check adds no trust UTERM-004 can use, since any process can run the signed CLI.

Leaves undone: nothing.

### REPL features

Original question: history, completion, and multi-line input; and whether the REPL applet is built on the terminal
applet, or is a native text view.

Decision: the REPL applet hosts a terminal session whose child is the REPL helper.

- The applet uses the terminal surface protocol of ADR-01, as the terminal applet does. The helper runs on the pty and
  does line editing with Janet's own line editor: history, symbol completion, and multi-line input driven by Janet's
  parser. Output reaches the screen as terminal output, bounded by the terminal's scrollback.
- Control channel: the app passes the helper its listener address as a program argument, and a single-use token in
  its environment. The helper connects and presents the token, which binds that connection to the REPL's pane and is
  spent on first use.
- The binding keeps a connection from attaching to the wrong pane. It is not a defense against other processes of the
  same user, which can read a process's original environment and open the user's own terminal devices. No rule in
  this proposal trusts a REPL more than any other peer of the same user, so nothing depends on it. A binding that
  holds against same-user processes is UTERM-004's to design.
- The helper starts in the home directory. Before running any user code, it drops every inherited environment
  variable, the token included. The REPL applet reports no current directory. Nothing flows into a REPL from the app's
  environment or from another pane.
- Ctrl-C reaches the helper as an interrupt and stops the running evaluation, per "Where scripts run".
- The REPL applet has its own description type. It saves the REPL's history as inert text and never re-evaluates it.
  A restored REPL starts a fresh helper with that history to recall, per ADR-03.

Rationale: the terminal already bounds and coalesces output, and brings selection, copy, find, font, and theme. Script
input and output work the same as under `uniterm run`. A native transcript would pull unbounded script output into the
app's memory and main thread, which "Where scripts run" exists to prevent, and would need flow control, a stdin
source, and a completion protocol that stalls while an evaluation runs. The terminal launch can pass only a working
directory, environment, and program, and ADR-01 bars reaching past that protocol, so the environment is the one
channel to the helper. It is explicit plumbing, scoped to one connection.

Leaves undone: nothing.

## Design Decisions (Open)

## Risks

- **The host API and the `uniterm run` command line become public contracts that scripts depend on** — likelihood:
  high, impact: medium.
  Mitigation: version the API from the first release, and keep the first set small. The command line's flags, such as
  `--allow`, take Janet's capability names, so they change only when Janet's do.
- **A Janet panic or crash takes down a helper** — likelihood: medium, impact: low.
  Mitigation: every call into Janet in the helper goes through `janet_pcall`, and a helper's death ends one run or one
  REPL, never the app. Fixture tests cover panics.
- **A runaway or oversized script degrades the machine** — likelihood: medium, impact: medium.
  Mitigation: Janet never runs in the app, and the main thread never waits on a helper. Ctrl-C stops an evaluation.
  The app kills a helper past its memory bound.
- **The app-to-helper protocol skews across an in-place update** — likelihood: medium, impact: medium.
  Mitigation: a version handshake refuses a mismatch with a message to relaunch uniterm, and the `uniterm` command is
  always a symlink into the bundle.
- **UTERM-004 picks a caller-identity mechanism that does not build on this one** — likelihood: medium,
  impact: medium.
  Mitigation: Impacts names the peer audit token and PID as the base for UTERM-004's open question, and says the REPL
  token binding is not a same-user defense. Any change lands before UTERM-004 M1, while only the REPL uses them.
- **Any process of the same user can drive panes once M3 lands, before UTERM-004's trust rules exist** — likelihood:
  medium, impact: medium.
  Mitigation: no host function writes to a terminal's input, so a script cannot type into a shell or an ssh session.
  The listener is reachable only by the user's own processes. Accepted for the rest: the same user can already
  control the app's windows through Accessibility.
- **REPL history is saved in plain text in the layout file** — likelihood: medium, impact: low.
  Accepted: it matches shell history files, and the layout file is private to the user. History is bounded in size.

## Milestones

### M1: Embedded Janet and the first host function

**Status:** DONE

- Janet is vendored from a recorded tagged release and builds into the helper executable, which ships in the bundle
- The app and a helper connect, exchange a protocol version, and refuse a mismatch
- One host function, such as posting a status message, works from a script
- A script error is reported with the script name, line, and message, and the app keeps running

**As built:**

- Janet v1.43.0 is vendored by `scripts/vendor-janet.sh` and recorded in `janet.pin`, which holds the tag, the commit,
  the tarball hash, and the hash of each copied file. Janet's own make builds the amalgamation. `make check` verifies
  the copies against the pin, and `make licenses` carries Janet's license after checking it against the pin. The line
  editor's source is vendored from the same tag and left out of the build until the REPL needs it.
- `janetconf.h` is the upstream file plus a block that the script appends. The block routes every allocation through a
  counting wrapper and turns off native modules. The wrapper only counts. M5 adds the cap.
- Only the helper targets reach Janet. A C shim holds every call into it and every host function, so Swift never sees
  `janet.h` and a Janet error never unwinds a Swift frame. Each host function checks its arguments in C, then calls a
  Swift callback that cannot throw, and raises any failure from C.
  `scripts/check-janet-isolation.sh` fails when the app target, the host target, or the wire target can reach Janet. It
  runs in `make check` and `make build`.
- The `uniterm` command is an Xcode tool target named `UnitermCLI` with the product name `uniterm`, embedded in
  `Contents/Helpers`. A SwiftPM executable is its twin for the package tests. The command uses the hardened runtime and
  holds no entitlements. `check-sandbox-off.sh` names it as the deliberate exception. It insists that the built command
  exists, verifies its signature, and holds no sandbox or other entitlement. The sandbox is off for it per the Decision
  Log entry of 2026-11-09.
- Janet's sandbox is already applied, with file, network, process, FFI, environment, signal, thread, and chroot access
  denied. A fixture proves that a plain file read fails. M3 clears a capability's bit when the command line names it.
- The wire is a new target that reuses the framed socket. Hello is one version field in every version. Next come the
  script's name, requests with an ID and a function code, and replies that carry the same ID and either a payload or a
  failure with a kind and text. The app answers a helper's hello with its own before it refuses a mismatch, so the
  helper tells the user to relaunch uniterm and exits with status 70. A fuzzer for it runs in `make fuzz`.
- The app listens at `Application Support/uniterm/run/<pid>.sock`. The folder is created private to the user, and
  refused when it is a symlink or another user's. Debug builds read `UNITERM_SCRIPT_DIR`, and the UI test base class
  points it under `/tmp`, since a UI test's scratch folder is too long for a socket path. The listener records each
  peer's user, process, and audit token, and refuses a peer of another user. A thread for each connection reads and
  decodes. The main actor gets each call through an `AsyncStream`. Replies go to a writer queue that is unbounded for
  now, so M3 bounds it. At most 32 peers connect, a peer has 5 seconds to say hello, and at most 8 of its calls wait
  for an answer.
- `post-status` posts through a producer from the active window's status center, named for the script, so a script
  never posts as uniterm. With no window open, the call fails with a refusal the script sees.
- The script mode is `uniterm run --socket PATH file.janet`. A script error prints `name:line:col: kind error: message`
  to stderr and exits 1, and the connection closes. The tests show the app serving the next script after a runtime
  error, a compile error, and a parse error.
- A helper at rest holds 3,211,624 bytes of physical footprint, 3.1 MiB. It takes about 12 ms from launch to its first
  message after the hello. Both numbers are the same for the package twin and the bundled command, which are Debug
  builds. A release build is not measured.
- Left for later milestones: the well-known address, its lock, and cleanup of the socket file that a crashed instance
  leaves behind. A reader thread in the helper for Ctrl-C and the watchdog. Running Janet's event loop after the script
  ends. Bounding the writer queue. No UI test covers the app's wiring.

### M2: Host API v1

**Status:** NOT STARTED

- Scripts can list windows and panes, open a pane with an applet, and open a terminal tab
- Each host function rejects bad arguments with an error to the script
- Script fixtures exercise every host function, including error cases, in `make test`
- A host function rejects a window, pane, or tab ID that is not an exact integer in range
- A reference to a pane from an earlier launch resolves to nothing, never to another pane
- Window IDs stay unique across launches even when the system clock moves backwards between them
- A pane opened by a script starts in the directory the call names, or else the one its neighbour pane reports
- Sending to a terminal applet or a REPL applet is refused with an error to the script

### M3: `uniterm run`

**Status:** NOT STARTED

- `uniterm run file.janet` runs the script against the running app
- With no app running, the command reports that clearly
- Each run has its own VM process, and no such process outlives the app
- A helper built from a different protocol version is refused with a message to relaunch uniterm
- uniterm can install the `uniterm` command on `PATH` as a symlink into its bundle
- A `uniterm` command that is not the bundle's own is refused with a message to reinstall the command
- The listener rejects a peer that runs as a different user
- A second uniterm instance, such as one a UI test launches, neither takes over nor breaks the first one's socket,
  and its REPLs reach it, not the first instance
- A peer that never reads replies cannot grow the app's memory
- A run whose app quits exits nonzero with a message naming the cause
- A capability is granted to a run only when its command line names it
- After the owner of the well-known address quits while a second instance runs, `uniterm run` reports that no app is
  reachable, and never connects to a stale socket
- Tests can point `uniterm run` at a test instance's own address, so a UI test never runs scripts against the user's
  uniterm
- A helper busy in a loop still exits when its connection to the app closes

### M4: REPL applet

**Status:** NOT STARTED

- A pane can run the REPL applet
- Expressions typed in the REPL call the host API and show results
- Each REPL pane has its own helper process, and closing the pane ends it
- A REPL helper's token is spent before any user code runs, and a token presented a second time is refused
- A REPL starts in the home directory with none of the app's environment
- When a REPL's helper dies, the pane stays open with a message and a way to restart, and keeps its history
- The app keeps its own copy of REPL history as lines are entered, so saving a layout never waits on a helper
- Closing a REPL at an idle prompt does not ask for confirmation
- REPL history survives a close and an undo, never re-runs on restore, and is bounded in size in the layout file
- Ctrl-C stops a running evaluation and returns to the prompt

### M5: Sandbox and limits

**Status:** NOT STARTED

- A script fixture that tries a denied operation fails with the expected error
- A script in an infinite loop stops on Ctrl-C, and the app stays responsive while it runs
- Interrupting a runaway REPL evaluation keeps the REPL's earlier definitions
- A script in a long, legitimate loop is never killed for not answering, since the watchdog thread answers the app
- A helper stuck in a C call the interrupt never reaches, such as a long `peg/match`, can still be ended by the user
- A script that allocates without limit ends with a memory error, and the app keeps running
- A REPL helper whose footprint passes the cap outside Janet's allocator is killed by the app, and its pane says why
- While the REPL helpers' total footprint is over the app-wide budget, a new REPL does not start, its pane says why
  and offers a user-only retry, the history holds one warning, and no running REPL is killed for the total. Amended
  2026-11-06; see Decision Log.
- M1 records a helper's resting footprint and startup time in its As built block

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-11-01: Added context from UTERM-001's implementation to "API naming and shape": pane ID scope and
  undo.
- 2026-11-02: Review start: 5 milestones, 4 settled decisions, 3 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; at e2da0f1. The user asked for a full design review in autonomous mode.
- 2026-11-02: Where scripts run: one VM per run and per REPL, each in a helper process outside the app (autonomous).
  Revises the settled "Janet is the embedded language", which said Janet is compiled into the app.
- 2026-11-02: API naming and shape: launch-unique window IDs plus pane IDs, as plain-data references in one `uniterm`
  module (autonomous).
- 2026-11-02: How `uniterm run` reaches the app: the CLI is the helper, runs the VM in its own process, and connects
  over a per-user Unix socket; the command on `PATH` is a symlink into the bundle (autonomous).
- 2026-11-02: REPL features: a terminal session running the REPL helper, with Janet's line editor and a single-use
  environment token binding its connection to the pane (autonomous). The token is state passed through the
  environment, raised for the user's decision at the review gate per CLAUDE.md "Applet Attributes".
- 2026-11-02: Coherence review: corrected Impacts on UTERM-002, which never routes the palette through Janet
  (autonomous).
- 2026-11-02: Each instance listens at its own address and passes it to its REPL helpers; the first instance claims the
  well-known address for `uniterm run` (autonomous).
- 2026-11-02: A REPL helper starts in home and drops its inherited environment (autonomous). A pty challenge added in
  the same review was dropped after the re-check showed a same-user process can open the pane's terminal and answer
  it. The token binding is stated as guarding against misbinding only (autonomous).
- 2026-11-02: Sandbox grants: a run gets a capability only when its command line names it; a REPL gets none here
  (autonomous, addition). Deferred: REPL grants. **Revisit:** when UTERM-004 settles control levels.
- 2026-11-02: Panes and tabs a script opens start in the directory the call names, or else the one the neighbour pane
  reports; the CLI's directory never flows in (autonomous). Raised for the user per CLAUDE.md "Applet Attributes".
- 2026-11-02: No host function writes to a terminal's input (autonomous).
- 2026-11-02: Out of scope: invoking or registering registry commands from scripts, which answers UTERM-002's risk on
  Janet-backed actions by not building them here (autonomous).
- 2026-11-02: Sandboxing: no CPU limit on runs and REPL evaluations; Ctrl-C stops them. Before, a watchdog bounded CPU
  time. A script can no longer freeze the app, and a budget would cut off legitimate long runs (autonomous). Narrows a
  settled decision, for the user at the review gate.
- 2026-11-02: Risk review: the `uniterm run` command line joins the host API as a public contract (autonomous).
- 2026-11-02: Review gate, first call: kept no CPU limit on runs and REPL evaluations; kept the neighbour-directory
  fallback for panes a script opens; kept the REPL environment token, `uniterm run --allow`, saved REPL history, and
  the `PATH` symlink installer. The helper-process revision is under discussion.
- 2026-11-02: Review gate: kept the helper-process revision of "Janet is the embedded language", after discussing how
  a process bounds memory and what one process per run or REPL costs.
- 2026-11-02: Memory cap in two layers: a counting allocator in each helper that exits it cleanly at the cap, and the
  app killing a helper it spawned whose footprint passes the cap; the app never kills a `uniterm run` process (user's
  decision at the review gate).
- 2026-11-02: Memory sizes: 1 GiB per helper; an app-wide budget for REPL helpers of 4 GiB or a quarter of physical
  memory, whichever is smaller, enforced by refusing new REPLs while over it; no setting for either (addition, user's
  decision at the review gate).
- 2026-11-02: Review gate: nothing reopened.
- 2026-11-02: ADR candidate (cuts across the system): Janet never runs in the app process. Declined: the user asked for
  the principle behind it, written as ADR-07.
- 2026-11-02: ADR candidate (cuts across the system): the main thread never waits on a script. Declined: the user asked
  for the principle behind it, written as ADR-08.
- 2026-11-02: ADR candidate (hard to reverse): IDs handed to scripts are valid for one launch. Declined: an
  implementation, not architecture. Its invariants are listed in "Invariants scripts rely on".
- 2026-11-02: ADR candidate (hard to reverse): the host API is versioned from its first release. Declined: the
  embedding standard already requires it.
- 2026-11-02: ADR candidate (cuts across the system): scripts are denied file, network, process, and FFI access by
  default. Waits on UTERM-004 settling control levels, which may change how access is granted.
- 2026-11-02: ADR candidate (cuts across the system): a failure ends only what failed. Written as ADR-07.
- 2026-11-02: ADR candidate (cuts across the system): the UI never waits on unbounded work. Written as ADR-08.
- 2026-11-02: Accepted. ADR-07 and ADR-08 stay proposed until an implementation validates them, at the user's request,
  so neither needs rework if implementation shows it cannot hold as written.
- 2026-11-02: Risks rewritten for helper processes; added protocol skew, UTERM-004 identity exposure, same-user
  control before UTERM-004, and plaintext REPL history (autonomous).
- 2026-11-03: Scheduled as UTERM-003 M1-M5 in queue.md.
- 2026-11-06: Amended the app-wide REPL budget refusal and its M-check (work-queue best guess). The text said the status
  bar says why a new REPL does not start. A status message may clear in 5 seconds and leaves an empty pane with nothing
  to read. UTERM-017 "Placement of refusals" has the empty pane carry a durable explanation, record one warning in the
  history, and leave any retry to the user, since ADR-03 forbids a restore from running a program. This proposal's
  milestone wires it when the REPL is built.
- 2026-11-09: Amended "Where scripts run" and "Sandboxing" to say that the helper is not in the App Sandbox
  (work-queue best guess). The text said nothing about the helper's sandbox, and the proposal's own checks needed the
  rule stated. `uniterm run` reads the script by path, connects to a socket by path, and may hold `--allow fs-read`. A
  REPL helper launches through a terminal. The terminal launch can pass only a working directory, an environment, and a
  program, and ADR-01 bars reaching past that protocol, so the helper must connect by path. ADR-10's last bullet lets a helper skip the sandbox with a stated reason, so ADR-10 is not edited.
  Janet's sandbox, the memory cap, and process isolation bound the helper instead.

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, APPLET-9
- Coding standards: `languages/janet.md` and `languages/lisp-embedding.md`
- ADR-02: pane tree nodes have stable IDs
- ADR-07 (proposed): Failure Isolation. A failure ends only what failed
- ADR-08 (proposed): UI Responsiveness. The UI never waits on unbounded work
