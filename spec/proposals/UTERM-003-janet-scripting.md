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

- A pane or tab a script opens starts in the directory the call names. The directory is an absolute path to a folder
  that exists, and a relative one is refused. When the call names none, a pane opened beside another starts in the
  directory that pane reports through the applet contract, as a split from the UI does. A tab a script opens starts in
  the directory its own pane reports. When the pane reports none, the applet's own default applies, which for a
  terminal is the home directory. The CLI's working directory never flows in implicitly.
- A send names an existing pane, and carries bytes and a file name, never a path. A script that wants a new viewer opens
  a pane first, then sends to it.
- No host function in this proposal writes to a terminal's input. An applet whose input belongs to a program, which a
  terminal and the REPL applet do, declares that, and a send to it is refused with an error to the script.

Amended 2026-11-09; see Decision Log.

### Invariants scripts rely on

Scripting is viable only if these hold. Every host function, and every later change to the host API, keeps them:

- A reference to a window, pane, or tab never resolves to a different one. A reference to one that is gone resolves to
  nothing. A question about panes answers nil for a window that is gone, and a call that acts on one fails with a
  not-found error that names no other pane. Amended 2026-11-09; see Decision Log.
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
  freeze the app, since the main thread never waits on a helper. In a run, the first Ctrl-C stops the script, and the
  command exits with status 130 and the word "interrupted". A second Ctrl-C ends the process at once, so a script stuck
  in a C call that the interrupt never reaches still ends. In a REPL, Ctrl-C reaches the helper as SIGINT. The pane
  also sees the key and sends the app's own stop request over the control channel, so the stop does not depend on the
  pty's signal arriving. Both end in one SIGINT handler on the VM's own thread, which stops the evaluation. A second
  Ctrl-C in the pane, after a short gap and with the form still running, kills the helper. The helper's watchdog thread
  reads the connection, answers the app's ping, carries out the stop request, and ends a helper whose connection
  closes. The helper blocks SIGINT on every thread but the VM's, in a run as in a REPL, so the handler runs on one
  thread only.
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
  cap, and process isolation bound the helper instead. The last bullet of ADR-10's Decision allows this.
- Host API calls are messages from the helper to the app. The app runs each one on the main thread and replies.
- The main thread never waits on a helper. Any later Janet-backed action the app runs sends its message and returns.
- A running evaluation stops on Ctrl-C or on the app's stop request, and the VM keeps its state. Ctrl-C is SIGINT,
  handled on the VM's own thread. The stop request is the watchdog thread's, and it signals the VM's thread, so both
  take the one handler. The app kills a helper in four cases only. The helper leaves a ping unanswered for 3 seconds.
  Its footprint passes the cap by a quarter. The user presses Ctrl-C twice while a form ignores the first. It outlives
  its closed pane. A helper that answers is never killed for working long.
- Memory is capped in two layers:
  - In the helper: `janetconf.h` routes Janet's allocator through a counting wrapper. An allocation that would pass the
    per-helper cap fails, and the helper exits with status 79 and a memory-limit message. A REPL helper first sends
    one frame through its connection's own locked send, so the pane can say why. The failure path formats nothing and
    uses no stdio, so output a script printed and did not flush may be lost. It does not try to recover, since Janet's
    out-of-memory path is not safe to unwind. This layer covers every helper, `uniterm run` included.
  - In the app: the app reads the footprint of each helper it spawned with `proc_pid_rusage` once a second, off the
    main thread. It kills one that passes the cap by a quarter of the cap, 1.25 GiB in all. This catches memory the
    counting wrapper does not see. A `uniterm run` process is the user's
    own process, which the app did not start, so the app never kills it; the first layer bounds it.
  - A helper that ends for memory reports it: the REPL pane shows the message and offers a restart, and a run exits
    nonzero with the message on stderr.
  - The cap is 1 GiB per helper.
- An app-wide budget bounds the REPL helpers the app spawned, taken together. It is 4 GiB, or a quarter of physical
  memory when that is smaller. While their total footprint is over the budget, a new REPL does not start. The empty
  pane says why and offers a retry that only the user can run, and the history records one warning. A restored pane
  never retries on its own. A running REPL is never killed for the total. Admission reads the footprint of each
  attached helper fresh, and counts a helper that was admitted and has not attached for a floor of 8 MiB. The total
  at admission is therefore at most the budget, and one admission adds at most one cap beyond it. Helpers that
  already run may still grow, each to its own cap, and the total never ends one of them. The history records one
  warning for each over-budget episode, which ends when the total is back under the budget. `uniterm run` processes
  do not count, since each is the user's own and is capped. Amended 2026-11-09; see Decision Log.
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
  one from an earlier launch, resolves to nothing. It never resolves to a different pane. A call that acts on one
  fails with a not-found error. A tab reference is accepted wherever a pane reference is, and must still name an open
  tab of that pane. Amended 2026-11-09; see Decision Log.
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
- The script's output, input, arguments, working directory, and exit status are the CLI process's own. The
  arguments after the script's file reach the script through `(dyn :args)`, the script's own path first, as under
  Janet's own command. Ctrl-C or a kill on the CLI stops the VM and closes its connection. Nothing is relayed through
  the app.
- REPL helpers connect to the same listener, per "REPL features".
- Each running instance listens at its own address, and passes that address to its REPL helpers. The first instance to
  start also claims the well-known per-user address, under a lock that tells a live owner from a stale socket.
  `uniterm run` connects to the well-known address, unless `--socket PATH` or the environment variable
  `UNITERM_SOCKET` names another, and the flag wins. A second instance, such as one a UI test starts, never takes it
  over, and it does not take it over after the owner quits either. Once the owner quits, `uniterm run` reports that no
  app is reachable until a new instance starts with the address free. Amended 2026-11-09; see Decision Log.
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
  spent on first use. The token is the first message after the version, in place of a script's name. The app answers
  with the history to recall, or with a refusal that says why and closes the connection. A refused connection can call
  nothing. The helper then reports each line the user enters, and whether a form is evaluating.
- The binding keeps a connection from attaching to the wrong pane. It is not a defense against other processes of the
  same user, which can read a process's original environment and open the user's own terminal devices. No rule in
  this proposal trusts a REPL more than any other peer of the same user, so nothing depends on it. A binding that
  holds against same-user processes is UTERM-004's to design.
- The helper starts in the home directory. Before running any user code, it drops every inherited environment
  variable, the token included. The REPL applet reports no current directory. Nothing flows into a REPL from the app's
  environment or from another pane.
- Ctrl-C reaches the helper as an interrupt and stops the running evaluation, per "Where scripts run". At an idle
  prompt it clears the line. The pane also sees the key and sends the app's stop request, which does nothing when no
  form runs. A second Ctrl-C, at least half a second after the first and within five seconds of it, with the form still
  running, ends the helper. The pane then says so, keeps its history, and offers Restart.
- The helper runs the loop itself, with Janet's parser and Janet's line editor. An error in a form is printed and the
  prompt returns, and the definitions stay. It does not run Janet's event loop, so a function that waits on the event
  loop, such as `ev/sleep`, does not run its fiber.
- The REPL applet has its own description type. It saves the REPL's history as inert text and never re-evaluates it.
  A restored REPL starts a fresh helper with that history to recall, per ADR-03. The app keeps the newest 500 lines or
  256 KiB of them, whichever is less, and the line editor recalls the newest 100.
- A REPL is busy only while the helper reports a form evaluating, so closing at an idle prompt asks nothing.
- When the helper dies, the pane stays open with its last output, a message, and a Restart button that only the user
  can press. The history carries over. Closing the pane closes the connection, which ends the helper, and the app kills
  a helper that is still there after two seconds and is still the process that attached.
- A script cannot open a REPL pane, since `open-pane` offers no kind that starts a helper. The user opens one from the
  launcher.

Amended 2026-11-09; see Decision Log.

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
  now, so M3 bounds it. At most 32 peers connect, a peer has 5 seconds from connecting to declare itself a script or a REPL and may not call before it does, and at most 8 of its calls wait
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
  leaves behind. A reader thread in the helper for Ctrl-C and the watchdog, which M4 and M5 built. Running Janet's event loop after the script
  ends. Bounding the writer queue. No UI test covers the app's wiring.

### M2: Host API v1

**Status:** DONE

Amended 2026-11-09; see Decision Log.

- Scripts can list windows and panes, open a pane with an applet, and open a terminal tab
- Each host function rejects bad arguments with an error to the script
- Script fixtures exercise every host function, including error cases, in `make test`
- A host function rejects a window, pane, or tab ID that is not an exact integer in range
- A reference to a pane from an earlier launch resolves to nothing, never to another pane
- Window IDs stay unique across launches even when the system clock moves backwards between them
- A pane opened by a script starts in the directory the call names, or else the one its neighbour pane reports
- Sending to a terminal applet is refused with an error to the script, and the refusal is a property an applet
  declares, so M4's REPL applet adopts it
- Sending content to a viewer pane reaches the viewer, through a private folder that only the user can enter

**As built:**

- The host API has `list-windows`, `list-panes`, `open-pane`, `open-tab`, and `send`, beside `api-version` and
  `post-status`. The API version stays 1, since nothing M1 shipped changed. The wire's protocol version is 2, since
  the app and helper now speak new calls and a failure kind. A call that carries content has a frame type of its own,
  so only a send may make the reader allocate more than 64 KiB.
- References are structs or tables. Keys beyond the ones a function needs are ignored, so a pane reference serves as a
  window reference. `:tab` is checked wherever it appears. IDs go out as Janet numbers and come in through one check in
  the C shim that refuses a non-number, a fraction, NaN, infinity, a negative, and anything above 2^53 - 1. The app
  decodes IDs with the same limit and trusts nothing the shim did.
- Reply values cross as bytes. The Swift callback hands the shim the encoded reply, and the shim builds the Janet
  values after Swift returns, so no Janet error unwinds a Swift frame. The shim and Swift share one value format. The
  Swift side has a fuzzer. The shim's reader has its own tests against crafted bytes, in a test target that may reach
  Janet. A record holds at most 64 fields, and a repeated key is refused on both sides.
- A window's ID is a random 37-bit epoch drawn once per launch above a 16-bit counter. The ID never reads the clock.
  When the counter runs out, the source draws an epoch that no earlier epoch of the launch used. `WindowSet` assigns the
  ID when it registers a window, so a restored window gets a new one. The tests show that two launches that draw
  different epochs share no ID. They cannot move a clock, since the ID has no clock input.
- A tab has a small number per window, issued the first time a script sees it and never reused. The map only grows.
- `open-pane` kinds are `:terminal`, `:data-viewer`, `:map-viewer`, `:image-viewer`, `:text-viewer`, and `:browser`.
  There is no kind that runs a program. The axis is `:row` or `:column`. Without one, a wide pane splits side by side
  and a tall one is stacked, as a routed pane does, and a requested axis with no room is refused. A pane that fails to
  start also posts to the status bar, as a split from the UI does.
- `open-tab` goes through a small capability in the applet kit that the terminal in shell mode and the browser adopt.
  A browser tab has no directory, so a script that names one is refused. A terminal that runs one program refuses.
  Every other applet refuses.
- `send` works on an applet that takes a source and does not declare that its input is a program's. The terminal
  declares it now. The check runs before the source check, so an applet that does both is refused. A send is refused
  while the window has a sheet up, as an open-pane is, since the sheet can be that pane's own Save question. The app
  writes the bytes into `Application Support/uniterm/sent/<pid>.<start>/`, a folder for the instance, in a folder of
  its own for each send, at 0700 for folders and 0600 for files. A send is at most 1 MiB. The host ties each file to
  the pane that took it. A pane keeps its last file. The file goes, and its bytes return to the budget of 256 MiB, when
  a script sends another to that pane, or when a later call finds the pane closed. A file for a pane that the user
  changed with no script involved stays until a script next sends to that pane or the app relaunches. A launch removes
  the folders of instances that ended. The folder's name carries the process's start time, so a process ID that the
  system reused never keeps a dead instance's folder. The viewer starts in its own directory, or home, never in the
  private folder. Debug builds read `UNITERM_SENT_DIR`.
- A pane that a send filled saves its path in the private folder, so the next launch finds the file gone. Each viewer
  loads a restored path the same way it loads any, and shows its own message that the file is gone and keeps the
  path. The map, data, and image viewers have tests for it. The text viewer is traced by reading only.
- The directory a script names must exist, as a stat that follows links. The terminal falls back to home for a folder
  that is gone, and the script would never learn its path was wrong. The stat runs off the main actor, since a hung
  network mount would freeze the windows. `open-pane` and `open-tab` look the pane up again when it returns, so a
  pane that closed meanwhile is not found. A tab starts in the directory the call names, else in the one its pane
  reports, else in the applet's own default.
- A reply may hold at most 63 KiB. A listing too large for it fails with an error that says so, and gives no partial
  answer. Titles and directories from programs go through the status bar's text cleaner, which turns every control
  character into a space, drops bidirectional controls, and cuts to 256 bytes.
- Every host call runs on the main actor and never blocks it. `open-pane` and `open-tab` answer later, after the
  directory check. The only disk write on the main actor is a send's, which has a known size. Nothing opens a pane
  through the async router, since a send names a pane that exists.
- A bad argument fails in the shim and never reaches the app. A fixture for each function holds its error cases, and
  the tests show that none reached the app.
- No UI test covers the app's wiring of the window layer. M3's UI test of `uniterm run` can drive a script that opens a
  pane.

### M3: `uniterm run`

**Status:** DONE

- `uniterm run file.janet` runs the script against the running app
- With no app running, the command reports that clearly
- Each run has its own VM process, and no such process outlives the app
- A helper built from a different protocol version is refused with a message to relaunch uniterm
- uniterm can install the `uniterm` command on `PATH` as a symlink into its bundle
- A `uniterm` command that is not the bundle's own is refused with a message to reinstall the command
- The listener rejects a peer that runs as a different user
- A second uniterm instance, such as one a UI test launches, neither takes over nor breaks the first one's socket,
  and each instance hands its own address to the helpers it starts, through an API the REPL applet calls. M4 proves
  that the REPL reaches its own instance. Amended 2026-11-09; see Decision Log.
- A peer that never reads replies cannot grow the app's memory
- A run whose app quits exits nonzero with a message naming the cause
- A capability is granted to a run only when its command line names it
- After the owner of the well-known address quits while a second instance runs, `uniterm run` reports that no app is
  reachable, and never connects to a stale socket
- Tests can point `uniterm run` at a test instance's own address, so a UI test never runs scripts against the user's
  uniterm
- A helper busy in a loop still exits when its connection to the app closes

**As built:**

- The first instance to start owns the well-known address, `run/uniterm.sock` in the same private folder as the
  instance sockets. The address is a second listening socket that the same accept thread polls, not a link to the
  instance's own socket. Owning it means holding an exclusive `flock` on `run/uniterm.lock` for the instance's life.
  The lock descriptor is close-on-exec. When the lock is free, any file at the address is stale and is replaced. A
  later instance fails to take the lock, binds nothing at the address, and serves only its own `<pid>.sock`. On stop,
  the owner unlinks the address while it still holds the lock, then releases the lock. A later instance does not take
  the address over once the owner has quit. Tests cover the owner, a second instance, the owner quitting, a stale file,
  and the lock's release and close-on-exec.
- A start removes the `<pid>.sock` files that earlier instances left. The file's name has only the process ID, so the
  process's start time from the identity M2 introduced decides: a process that is gone, or one that started after the
  file's birth time, cannot own it, and its file is removed. A file of the current process, a running owner, a
  non-socket, or another user stays.
- `uniterm run [--allow CAPABILITY]... [--socket PATH] file.janet [argument...]`. Everything after the file belongs
  to the script and reaches it as `(dyn :args)`, the file's path first. The address is the flag, else `UNITERM_SOCKET`,
  else the well-known address under the home folder from the user database, never `HOME`. An empty value counts as not
  set. For the well-known address, the command checks that the file is a socket this user owns and not a link before it
  connects. A missing file, a refused connection, and a path that is not a folder all print `no uniterm is reachable at
  PATH` and exit 69. After connecting, the helper checks the peer's user ID, so it never sends a script's name to
  another user's socket. `--help` prints usage and exits 0. A usage error prints usage and exits 64.
- `--allow` takes the names Janet's `sandbox` accepts, from a table in the shim that mirrors Janet's own, and clears
  only that name's bits. A group name such as `fs` clears its members. `all` and any other name are refused with exit
  64 before the command connects. The default sandbox denies file, network, process, FFI, module, environment, signal,
  thread, and chroot access. It leaves `asm`, `compile`, `exit`, `hrtime`, `locale`, and `unmarshal` open, so
  `--allow` refuses those names too, since it would grant nothing. The usage text lists both sets. Fixtures show that
  a process call and a network listen are forbidden with no flag and pass the sandbox with `--allow subprocess` and
  `--allow net`. A script run does not drive Janet's event loop, so a connect or a child's exit status cannot be
  observed from a fixture. Fixtures show that a read fails with no flag, that `--allow fs-read` reads, and that
  a write stays denied under it.
- Each run has its own helper process. The helper starts a watchdog thread after the hello. The thread holds a kqueue
  on the connection's descriptor and never reads it, so only the VM thread consumes frames. On the app's end closing,
  it prints `uniterm quit, or closed the connection, while the script was running` and ends the process with status
  74. A call on the VM thread that finds the connection closed or broken ends the helper the same way, so a script that
  catches errors cannot go on. The VM thread flushes standard output before it ends the process. The watchdog does
  not, since it cannot know whether the VM thread holds the stdio lock, and a blocked flush would leave the helper
  running after the app quit. A run that the app's quit cuts off may therefore lose the end of its output, and all of
  what was buffered when the watchdog ends it. The two threads race, and no test pins which one wins. A fixture loop
  that never yields exits within the test's bound once the listener closes. M5 replaced the kqueue with a watchdog
  that is the only reader of the connection. See M5's As built.
- The command refuses to run unless its resolved path is `<name>.app/Contents/Helpers/uniterm` in a bundle whose
  `CFBundleExecutable` exists and is executable. It resolves the path with `_NSGetExecutablePath` and `realpath`, so a
  link is judged by where it leads. A refusal prints a message to reinstall the command and exits 78. The package
  twin passes `identity: .unchecked` from its own `main`, and nothing a user sets can turn the check off. Tests cover
  fake bundles, links, a copy, and a bundle with no main executable. The UI test runs a copy of the built command.
- The app menu has Install Command Line Tool, a registry command. A save panel opens in `~/.local/bin`, made first,
  with the name `uniterm`. The installer writes a symlink to `Contents/Helpers/uniterm` through a temporary
  link and `renamex_np`. An empty place is claimed with `RENAME_EXCL`, so a file that appears after the look is never
  replaced. A symlink is replaced with `RENAME_SWAP`, and when the entry that comes out is not a symlink, the swap is
  undone and the install is refused. A regular file, a folder, or anything else is refused and left alone. The app
  must not be translocated or on a read-only volume, since a link to such a path would dangle after the app quits. The
  install is refused with a message to move uniterm to the Applications folder. Tests cover both races and both
  locations. The success text says when the folder is not in a fixed list of usual `PATH` folders:
  `/usr/local/bin`, `/opt/homebrew/bin`, `/opt/local/bin`, `/usr/bin`, `/bin`, `~/.local/bin`, and `~/bin`. The app's
  environment is scrubbed, so it cannot read the real `PATH`.
- A connection's writer queue holds at most 64 messages and 1 MiB. A message past either bound closes the
  connection and reports `peerNotReading` to the status bar and the log. A test with a raw peer that sends 200,000
  calls and never reads sees the disconnect. A second test fills each bound alone.
- A test replaces the credential reader to play a peer of another user, and the listener refuses it.
- The host's instance address is this instance's own `<pid>.sock`, which M4's REPL applet passes to its helper. No test
  starts two app processes. A package test starts two listeners in one process, and the lock separates them.
- `open-tab` now refuses while the window has a sheet up, as `open-pane` and `send` do. The test failed on the
  unfixed code.
- A UI test, `ScriptRunUITests`, runs the bundled command against the test instance's well-known address in the
  test's own folder. The UI test runner is sandboxed and so is anything it starts, so the tests write a shell script
  into their scratch folder, type its path into the instance's terminal, and read the files the script writes. The
  shell is the unsandboxed app's child. One test checks the status bar message, a second pane, and the listing on
  standard output. The shell retries the command while it exits 69, so the wait for the app to listen is a real
  connect. A second test checks the no-app message and status, and that a copy of the command, made by the shell, is
  refused. The tests were built and not run by this milestone.
- The wire is unchanged, so its protocol version stays 2.

### M4: REPL applet

**Status:** IN PROGRESS

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
- A script's send to a REPL pane is refused with an error to the script, through the property M2 built.
- With two uniterm instances running, each REPL's helper reaches the instance that started it, not the other one.
  Amended 2026-11-09; see Decision Log.

**As built:**

- The REPL is the helper's `repl --socket PATH` mode. The pane hosts a terminal session whose program is the bundled
  command, and the token travels in `UNITERM_REPL_TOKEN`. The mode has no fallback to the environment or to the
  well-known address, since a REPL must reach the instance that started it. The helper reads the token, replaces its
  whole environment with an empty one, and enters the home folder from the user database. It then connects, presents
  the token, and waits for the app's answer. Debug builds also have `repl --probe-environment`, which runs those
  startup steps and prints the folder, the number of variables left, and whether the token was found. A package test
  runs it with a decoy environment and another working directory.
- The wire is protocol version 3. A helper's token message takes the place of `begin`, and a connection that has
  begun, or has called, cannot present one. The app answers with a history message or a refusal. The history is split
  across messages of 24 KiB at most, and the newest 100 lines are sent. A raw peer showed a spent token and an unknown
  token each refused, with the connection closed, and a refused connection posting nothing. See the Decision Log.
- Janet's line editor comes from the vendored `shell.c`, which is unchanged. A C file in the Janet target includes it
  with its `main` renamed, so the REPL reaches the editor's history without a hash change in `janet.pin`. The isolation
  check passes with no change. The loop around it is the target's own C. Each form runs in a fiber of its own, an error
  prints Janet's stack trace, and a result prints with `%q`. The `uniterm` module is imported before the sandbox is
  applied. The environment's `os/environ` is denied by the sandbox, and `os/cwd` is not.
- Ctrl-C is SIGINT. A handler on the VM's thread raises Janet's interrupt only while a form runs, and every other
  thread blocks the signal, so an idle Ctrl-C leaves no interrupt behind. A test shows a loop stopping, the
  definitions staying, and the next form running to the end. Another shows an idle Ctrl-C changing nothing. A pty test
  shows the editor recalling restored history on Up Arrow, and clearing the line on Ctrl-C.
- The editor puts back the terminal settings it found at its read. Before each form runs, the loop also sets ISIG when
  the terminal lacks it, so a terminal that starts without ISIG, or a restore the editor could not finish, never
  leaves Ctrl-C a plain byte. A package test starts the helper with `stty -isig` ahead of it and failed before this
  guard, showing `^C` echoed and the loop running on. The coordinator's UI run still showed Ctrl-C not stopping a
  loop in the real app. The cause there is not settled. Package tests start the helper through `login`, `bash`, and
  `/bin/sh -c`, as macOS libghostty starts a program, with SIGINT inherited as ignored, and with ISIG off. Each stops
  a loop with the byte 3. The helper installs its SIGINT disposition with `sigaction` and unblocks the signal on its
  own thread, so an inherited ignore or block does not matter.
  M5 adds a second path that does not depend on the pty's signal: the pane sends the app's stop request when it sees
  Ctrl-C while a form runs. A package test proves the stop request, and a UI test can prove the key path.
  A debug helper takes `--trace-sigint` and writes `[sigint evaluating]` or `[sigint idle]` to stderr on each SIGINT.
  The app passes the flag in debug builds when its startup snapshot of the environment holds
  `UNITERM_REPL_TRACE_SIGINT=1`, which the Ctrl-C UI test sets, and the failure message shows the screen. The process
  environment is scrubbed before the app starts, so the flag travels through the REPL's services and not through a
  later read of the environment. `TerminalUITests` also has a test that Ctrl-C ends a
  foreground `sleep` in a shell pane, so the app's key path is proved for an ordinary program.
- The app keeps its own history as the helper reports lines, bounded at 500 lines, 256 KiB, and 1,024 bytes a line,
  and the layout file holds that copy. A restored file's lines are checked again, and a line with a control character
  is dropped. A test shows a restored line that would post a status, write a file, and exit never running.
- A REPL is busy only while the helper reports a form evaluating. A window test shows a close at an idle prompt asking
  nothing, an undo bringing the history back to a fresh helper, and a close during an evaluation asking.
- A dead helper leaves the pane open with the terminal's last output above a strip with the message and Restart. The
  restart starts a fresh helper with the history. A close ends the helper by closing its connection. A helper still
  there two seconds later is killed when its process ID and start second still match what the app recorded at attach.
  Tests show the kill happening, and not happening for a reused process ID. A test caught a first draft that killed the
  test runner, since a raw peer in a test is the test process.
- The refusal of a script's send is the `InputOwning` property, adopted by the REPL. A window test against a real REPL
  pane shows it.
- Two package listeners in one process each issue tokens for their own address. A helper started with each one's
  address binds to its own instance, and a line typed in one never reaches the other. No UI test starts two
  instances.
- A launcher entry opens the REPL. It is the eighth, so Cmd-8 picks it, and the launcher's tests changed to match.
  Scripting now starts before any window, so a REPL that a window restores finds the listener.
- After a Ctrl-C stops a form, the rest of that line is dropped, so `(while true) (print 1)` never prints. A package
  test failed on the first build of the loop. Another runs the helper as a session leader on its own pty, as a terminal
  starts a program, and shows the byte 3 stopping a loop through the line discipline. It cannot show libghostty's own
  wrapping of the program.
- `ReplUITests` was built and not run by this milestone. The coordinator's first run showed that Escape does not
  dismiss the close question, so the test clicks Cancel as the other UI tests do, and that the older of two recalled
  lines did not appear in a narrow pane. The cause was the test, not the editor. Janet's editor draws one row and
  scrolls it to keep the cursor at the line's end, so a recalled line wider than the pane shows its tail and never its
  head. The test now matches the tail, and a package test on a 30-column pty pins the editor's display. Its tests drive the REPL from the launcher, a host call, a
  close at an idle prompt, a close during a loop, Ctrl-C, a close and undo, and a restart after `(os/exit 0)`.
- Not covered: the shell wrapper is proved to run the helper as the process the shell started, but only with
  `/bin/sh`. The terminal engine's own wrapping of the program is not tested. The event loop does not run in a REPL.
- Left for M5: the app's stop request, a helper stuck in C that Ctrl-C cannot reach, the memory cap and the app-wide
  budget, and the resting footprint of a REPL helper.

### M5: Sandbox and limits

**Status:** DONE

Amended 2026-11-09; see Decision Log.

- A script fixture that tries a denied operation fails with the expected error
- A script in an infinite loop stops on Ctrl-C, and the app stays responsive while it runs
- Interrupting a runaway REPL evaluation keeps the REPL's earlier definitions
- A script in a long, legitimate loop is never killed for not answering, since the watchdog thread answers the app
- A helper stuck in a C call the interrupt never reaches, such as a long `peg/match`, can still be ended by the user
- A script that allocates without limit ends with a memory error, and the app keeps running
- A REPL helper whose footprint passes the cap outside Janet's allocator is killed by the app, and its pane says why
- While the REPL helpers' total footprint is over the app-wide budget, a new REPL does not start, its pane says why
  and offers a user-only retry, the history holds one warning, and no running REPL is killed for the total.
- M1 records a helper's resting footprint and startup time in its As built block, and this milestone records a REPL
  helper's in its own

**As built:**

- Every category the default sandbox denies has a fixture that fails with the sandbox's own error: a file read, a file
  write, a network listen, a process, FFI, and the environment. Each run ends with status 1. A REPL test attempts six
  denied operations in one session. Each fails, and the REPL goes on.
- A run installs a SIGINT handler for the script's life. The first SIGINT while the script runs stops it. The command
  prints `name: interrupted` and exits 130. A second SIGINT ends the process at once with status 130. Janet's own line
  editor has no such rule for scripts, so the two-press rule is this milestone's choice. A test spins one script,
  runs another against the same app while it spins, and stops the first with SIGINT.
- The watchdog thread is the only reader of the connection once a script or REPL starts. It hands each reply to the VM
  thread through a one-slot mailbox, answers each ping with a pong, and signals the VM thread for a stop request. A
  kqueue no longer watches the descriptor, since the read itself reports the hangup. The wire is protocol version 4,
  and the codec tests and the fuzzer cover its four new messages.
- The app pings each attached REPL helper once a second and kills one that leaves a ping unanswered for 3 seconds. A
  test runs a REPL in a loop for ten seconds of the app's own clock, which a test moves by hand. The helper answers
  each ping, and nothing is killed. A second test stops a helper with SIGSTOP, and the app kills it as hung after the
  grace.
- A form stuck in a C call that the interrupt never reaches ends by the user's second Ctrl-C. Janet 1.43's `peg/match`
  does check the interrupt flag, so the fixtures read standard input, which never ends. The fixture marks the
  point just before the read, and the test then waits until the helper's main thread is blocked in the kernel, so the
  first interrupt cannot land before the read begins. In a REPL, the second press
  comes at least half a second after the first and within five seconds. The app kills the helper only while the
  process is the one that attached. A double tap on an ordinary loop is read as one press, and the loop ends without
  a kill. A run needs no gap, since its second SIGINT is the helper's own.
- The allocator wrapper ends the process with status 79 and a message on stderr, and a REPL helper sends a notice frame
  first, so the pane says why. Unflushed output is lost, per the Decision Log. Debug builds take `--memory-cap BYTES`,
  which only a test uses. `(buffer/new 1e12)` never reaches the allocator, since Janet's integer check refuses it, and
  a fixture shows that it is an ordinary error. The memory fixtures ask for 2,000,000,000 bytes against the default cap,
  and grow a buffer against a 64 MiB cap. Both end with status 79. The pane's pty can report the helper's exit before
  the notice arrives. The pane then keeps its channel until the connection closes, and the notice replaces the
  generic message.
- A test with injected footprints shows a helper past the cap and its margin killed, with the pane saying why and
  offering Restart, and a footprint inside the margin left alone. The app never touches a `uniterm run` process.
- A test with two real helpers and injected footprints shows the app-wide budget refusing a new REPL with neither
  helper killed for the total. Only the helper that passed its own margin was killed. The restored pane is refused the
  same way and never retries. The floor of 8 MiB for an unattached helper is above the measured 3.2 MiB at rest.
- A REPL helper at rest holds 3,359,104 bytes, 3.2 MiB, and takes about 22 ms from launch to attach. The bundled
  command measures 3,375,464 bytes and 23 ms. Both are Debug builds. A release build is not measured.
- The real-app Ctrl-C gap is not reproduced in a package test. A helper that is the target of `exec -l` under `login`
  and `bash`, as the pinned libghostty starts a program, stops a loop on the byte 3. Reading the pinned Ghostty source
  found nothing in the child's setup that would hold back SIGINT. The pane now also sends the app's stop request on a
  Ctrl-C key press. Which path carries the stop in the real app is for the UI tests to show.
- A SIGINT handler stays installed after a run or a REPL ends, and does nothing then. See the Decision Log.
- A run now blocks SIGINT on every thread but the VM's, as a REPL does, so the handler and its gate run on one thread
  in both modes. A run's second SIGINT still ends the process, since the signal reaches the VM thread even while it is
  blocked in a C call. The block starts after the helper connects, so a Ctrl-C during the connect still takes the
  default action.
- Proof boundary. The Ctrl-C and stuck-in-C checks are proved through the stop channel and through a real SIGINT to a
  real helper, in package tests. The app's key path, which sends the stop request when the pane sees Ctrl-C, waits
  on the real-app UI tests that M4 also waits on. `ReplUITests` gained the stuck-form test, and the UI tests were built
  and not run by this milestone. The key hook is proved only by reading and by the key classifier's unit test. No test
  sends the first Ctrl-C's SIGINT and the app's stop request together, so that the one handler balances both is
  unproved in the real app.

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
- 2026-11-09: Amended "Host API", "Invariants scripts rely on", and "API naming and shape" on what a reference to
  something gone does (work-queue best guess). The text said it "resolves to nothing", which reads as nil. A script
  that gets nil from an action can proceed as if it had a pane. A question about panes answers nil for a window that
  is gone, and every call that acts on a reference fails with a not-found error that never names another pane. A tab
  reference now also works where a pane reference is expected, and must name an open tab of that pane.
- 2026-11-09: Amended "Host API" on directories (work-queue best guess). The text said a call names a directory, with no
  rules for it. The directory must be absolute, since the helper's own working directory must never decide it, and it
  must exist, since the terminal's fallback to home would hide a wrong path from the script. A relative or missing
  directory is refused. A browser tab has no directory, so one named for it is refused too.
- 2026-11-09: Amended "Host API" and M2's check on sending to a terminal or a REPL (work-queue best guess). The text
  said sending to a terminal or a REPL applet is refused. M4 builds the REPL applet, so M2 cannot prove its refusal.
  M2 builds the refusal as a property an applet declares and proves it with the terminal and a stand-in. M4 adopts the
  property for the REPL and proves it there. M4 gains a check for it.
- 2026-11-09: Amended "Host API" on what a send names (work-queue best guess). The text said a send goes to an applet
  for display, and the plan said a send for a new pane uses the open-pane path. A send names an existing pane. A script
  that wants a new viewer opens a pane, then sends. This keeps the async router out of the host API, since no call
  waits on a new pane's file.
- 2026-11-09: Sent content lives in a private folder per instance, and the host ties each file to its pane
  (work-queue best guess, amended in review). The first guess said nothing removes a file when its pane lets it go,
  since a release hook in every viewer looked costly, and relied on a 256 MiB budget that never freed. That let one
  viewer take 256 sends and then refuse every later one. The host now knows the pane of each send. It removes the
  pane's previous file when the pane takes another, and removes the file of a pane that has closed, then returns the
  bytes to the budget. A pane's last file stays until then. No viewer changed. A change the user makes to a pane with
  no script involved is not seen, so its file stays until the next script send to that pane or a relaunch.
- 2026-11-09: A tab a script opens starts in the directory its pane reports (work-queue best guess, raised for the user
  per CLAUDE.md "Applet Attributes"). The first build left it to the applet, so a terminal's own fallback
  `currentDirectory ?? home` decided it out of sight. The host now passes the pane's reported directory, as open-pane
  does, and the applet's own default applies only when the pane reports none, which for a terminal is home. If wrong,
  the host would pass nothing and rely on each applet's rule again.
- 2026-11-09: The wire gains a `notFound` failure kind and its protocol version is 2 (work-queue best guess). The kind
  lets a script tell a reference to something gone from its own mistake. The version moves because the app and helper
  now speak new calls, a new frame type, and the new kind, and an old peer would read them as a protocol violation. The
  API version stays 1.
- 2026-11-09: A later instance never takes over the well-known address, even after the owner quits (work-queue best
  guess). The proposal says a second instance "never takes it over", and the check only needs `uniterm run` to never
  connect to a stale socket. Keeping the literal reading means a user who quits the first instance while a second one
  runs gets "no uniterm is reachable" from `uniterm run` until a new instance starts. If wrong, a later instance would
  retry the lock when the owner stops, which needs a wake-up from the owner's quit.
- 2026-11-09: The address is chosen by `--socket`, else `UNITERM_SOCKET`, else the well-known address, and the flag wins
  (work-queue best guess). The check asked for a way to point tests at an instance and left precedence open. A flag is
  the more specific and visible choice. If wrong, swapping the order changes only the resolution function.
- 2026-11-09: Script arguments reach the script as `(dyn :args)`, with the script's own path first (work-queue best
  guess). The text left the convention open. This is Janet's own convention for `janet file.janet args`. Everything
  after the file belongs to the script, so a script's own `--allow` is never read as the command's.
- 2026-11-09: Split the REPL half of the second-instance check (work-queue best guess). A REPL applet is M4's, so M3
  cannot show a REPL reaching its own instance. M3 proves the hand-off: `ScriptHost.instanceAddress` is the instance's
  own address and never the well-known one. M4 proves the REPL passes it and reaches its instance, and gains that
  check.
- 2026-11-09: The well-known address is a second listening socket under a lock, not a symlink to the instance socket
  (work-queue best guess). A link left by a crash could point at a socket of an unrelated process that reused the ID.
  A separate socket file at the address fails to connect once its owner is gone. The cost is a second descriptor in the
  accept loop.
- 2026-11-09: Leftover `<pid>.sock` files are removed by comparing the file's birth time to the process's start time
  (work-queue best guess). The socket's name carries no start time, so the identity M2 used in the sent folder's name
  does not fit as is. A gone process, or one that started after the file was made, cannot own the file. If wrong, a
  start time in the name would need a change to the instance address.
- 2026-11-09: A lost connection ends the helper with status 74, and a refused location ends it with status 78
  (work-queue best guess). The statuses are new public contract, beside 64, 66, 69, and 70, from sysexits.h. A script
  cannot catch a lost connection, since a script that survives its app would run without the host API it depends on.
- 2026-11-09: The command's bundle check is a parameter of the helper's entry point, which only the package twin's own
  `main` sets (work-queue best guess). An environment variable or a flag would let a user turn the check off. If wrong,
  a build flag in the twin could do the same job.
- 2026-11-09: The installer's `PATH` heuristic is a fixed list of common folders plus `~/.local/bin` and `~/bin`
  (work-queue best guess). The app's environment is scrubbed, so it cannot read the real `PATH`. A folder off the
  list gets a hint, not an error, since it may still be on the path.
- 2026-11-09: A connection's writer queue holds at most 64 messages and 1 MiB, and overflow disconnects the peer
  (work-queue best guess). A helper runs one call at a time, so a well behaved one never has more than one reply
  waiting, and the limits leave room for sixteen of the largest replies.
- 2026-11-09: `open-tab` joins `open-pane` and `send` in refusing while the window has a sheet up (work-queue best
  guess, from the M2 review). The sheet can be the pane's own Save question, so the pane must not change under it.
- 2026-11-09: `--allow` refuses a name the default sandbox already leaves open (work-queue best guess, from the M3
  review). `--allow hrtime` would read like a grant and do nothing. The default already denies network, process, and
  FFI access, which matches "Sandboxing", so nothing there changed. The refused names are `asm`, `compile`, `exit`,
  `hrtime`, `locale`, and `unmarshal`, and the usage text lists them beside the grantable names.
- 2026-11-09: Output may be cut off when the app quits mid-run (work-queue best guess, from the M3 review). The helper
  ends with `_exit`, which drops what stdio buffered. The VM thread flushes first. The watchdog does not, since a flush
  that blocks on the stdio lock or a full pipe would keep the helper alive after the app quit, which the check forbids.
- 2026-11-09: The installer refuses a translocated or read-only app (work-queue best guess, from the M3 review). A
  link to such a path dangles after the app quits, so a warning is not enough. The message says to move uniterm to the
  Applications folder.
- 2026-11-09: The UI tests run the command from the instance's terminal (work-queue best guess, from the M3 review).
  The runner is sandboxed, and a process it starts inherits that. The app's shell is unsandboxed, so it can connect,
  and the tests read the files the shell writes.

- 2026-11-09: The wire is protocol version 3, and a REPL's token is its own first message (work-queue best guess). The
  text said the helper "presents the token" and fixed no message. A token message in place of `begin` keeps hello as
  it was and lets the listener refuse a second declaration. The app answers with a history message or a refusal. The
  refusal is a message, since a closed socket would not tell the user why. The helper reports each line and each
  change in whether a form runs. If wrong, the token could ride in `begin`, which would put a secret in the field the
  status bar shows.
- 2026-11-09: The REPL's loop is the helper's own C, not Janet's `repl` function (work-queue best guess). The text said
  Janet's line editor and parser. `repl` would decide for itself what an interrupt does, and what it prints for one.
  The loop keeps both in code the project reads. It does not run Janet's event loop, so `ev/` functions do not resume
  a fiber in a REPL. If wrong, calling `repl` would need an experiment on how it treats an interrupt.
- 2026-11-09: Ctrl-C in a REPL is SIGINT handled on the VM's thread (work-queue best guess). The text said the
  watchdog thread carries out Ctrl-C. A signal can reach any thread, so the REPL blocks it everywhere else. The handler
  raises the interrupt only while a form runs, since a raised count with no form would stop the next form at once. The
  watchdog keeps the hangup and the app's stop request. If wrong, a kqueue signal event on the watchdog would do the
  same job, with the same gate.
- 2026-11-09: The app keeps 500 lines, 256 KiB, and 1,024 bytes a line, and the editor recalls the newest 100
  (work-queue best guess). The brief left the bound open. Janet's editor holds 100 lines and 1,023 bytes a line, so
  the copy keeps more than recall can use, for the layout file. A line with a control character, a blank line, and a
  repeat are not kept, as the editor keeps none of them. If wrong, the bound is two constants.
- 2026-11-09: A REPL starts with an empty environment, in the home folder from the user database, and takes no address
  from the environment (work-queue best guess). The text said it drops every inherited variable. The helper replaces
  its environment block, since Darwin has no `clearenv`. It enters home itself, so the launch's directory is not the
  only thing keeping it there. It needs `--socket`, since an environment variable or the well-known address could reach
  another instance. The probe that proves this exists only in Debug builds. If wrong, a REPL given a missing socket
  would fall back to `UNITERM_SOCKET`.
- 2026-11-09: A REPL is busy only while its helper reports a form evaluating (work-queue best guess). The pty reports a
  program with no prompt marks as always running, and the helper emits none. If wrong, the helper could emit OSC 133 and
  the terminal's own answer would agree with the report.
- 2026-11-09: A dead helper leaves the pane with the terminal's last output and a strip with Restart, and closing ends
  the helper by closing its connection, then killing it after two seconds when its identity still matches
  (work-queue best guess). The text said a message and a way to restart. The last output may hold the reason, such as a
  refused token or a version mismatch. The identity is the process ID and start second the app recorded when the
  helper attached. If wrong, the strip could replace the terminal and show only the message.
- 2026-11-09: A script cannot open a REPL pane (work-queue best guess). The brief offered `:repl` among the kinds if it
  fit. M2's As built says no kind runs a program, and a REPL starts a helper process. The checks do not need it. If
  wrong, the kind is one entry in the kinds list, and a limit on how many a script may open waits on M5's budget.
- 2026-11-09: Scripting starts before any window opens (work-queue best guess). A REPL that a window restores at launch
  asks for its channel as it starts, and the listener did not exist yet. The applet also asks lazily, and shows a
  message with a Restart when scripting is off. If wrong, a restored REPL would show that message at every launch.
- 2026-11-09: The launcher offers the REPL as its eighth entry (work-queue best guess). The REPL needs a way in that is
  not a script. The entry is last, so the numbers of the others stay. Cmd-8 now picks the REPL, and the launcher's tests
  for wrapping and for a number past the end changed.
- 2026-11-09: ADR candidate (cuts across the system): an interactive-session applet such as the REPL may start its
  interpreter on restore, the way a shell-mode terminal starts a shell, but never re-runs input. ADR-03 names only shell
  mode. Undecided.
- 2026-11-09: The REPL sets ISIG on the terminal before each form runs, when the terminal lacks it (work-queue best
  guess, from the UI run). The editor restores only what it found at its read, so a terminal that starts without ISIG
  would leave Ctrl-C a plain byte. The guard touches no other setting. If wrong, a user who wants ISIG off for the
  REPL's evaluations has no way to get it, and that use has no known reason.
- 2026-11-09: The older-line recall check in the UI test matches the line's tail, not its head (work-queue best guess,
  from the UI run). Janet's editor scrolls a single row to keep the cursor at the end, so a narrow pane never shows the
  head of a long recalled line. The product is unchanged.

- 2026-11-09: The watchdog thread is the only reader of the helper's connection, and the wire is protocol version 4
  (work-queue best guess). The watchdog only watched for a hangup, and the VM thread read its own replies. A ping that
  arrives while the VM thread is busy or waiting then has no reader. The watchdog now reads every frame, hands replies
  to the VM thread through a mailbox, and answers pings itself. The app gains `ping` and `stop`, and the helper gains
  `pong` and a memory-limit notice. If wrong, a second socket for liveness would leave the reply path alone.
- 2026-11-09: The app's stop request signals the VM's thread, and does not touch Janet itself (work-queue best guess).
  The text said the watchdog thread carries out the stop request. A thread other than the VM's that raises the
  interrupt can land after the form ended and stop the next form. The watchdog sends SIGINT to the VM thread with
  `pthread_kill`, so Ctrl-C and the stop request meet in one handler that keeps the gate and the count. If wrong, a
  gate with a lock would let the watchdog raise it directly.
- 2026-11-09: In a run, the first Ctrl-C interrupts and a second ends the process, and the command exits 130 with
  "interrupted" (work-queue best guess). The plan asked to follow Janet's own CLI, which has no second-press rule for
  scripts. Its line editor only re-raises SIGINT at an idle prompt. A script stuck in a C call needs a way out, and a
  second press is the one the user already reaches for. If wrong, one press could end the process at once and lose the
  clean interrupt.
- 2026-11-09: In a REPL pane, a second Ctrl-C ends the helper when it comes 0.5 to 5 seconds after the first with the
  form still running (work-queue best guess). The text had no user action for a helper stuck in C. The gap keeps a
  double tap on an ordinary loop from killing a helper that was about to stop. The window keeps an old press from
  counting toward a new one. The helper itself never escalates in a REPL, since the key and the pty's signal both
  arrive for one press. If wrong, a Stop button shown while a form runs would do the same job.
- 2026-11-09: The pane's Ctrl-C sends the app's stop request as well as the pty's signal, with neither primary
  (work-queue best guess). The coordinator's UI run showed Ctrl-C not stopping a loop in the real app, and no cause was
  found. The key reaches the container as a key equivalent, which then tells the applet. A press with nothing running
  sends nothing. Both paths end in one handler, so a press that delivers both stops the form once. If wrong, the pane
  would rely on the pty's signal alone, as before.
- 2026-11-09: The app pings a REPL helper once a second and kills one that leaves a ping unanswered for 3 seconds, with
  no time bound (work-queue best guess). The text said the app kills a helper that stops answering and left the bounds
  open. `HelperLiveness` takes an optional time bound, since the image viewer's overrun rule would kill a legitimate
  long evaluation. An app whose main actor stalled for four sample intervals forgives the pings it has outstanding.
  If wrong, the grace and the interval are two numbers.
- 2026-11-09: The memory cap ends the helper with status 79, and a REPL helper first writes a notice frame (work-queue
  best guess). The text said a memory-limit status and message. Sysexits names no status for it. The terminal engine
  reports no exit status to the pane, so the notice is how the pane says why. The write is one `write(2)`, since
  nothing else is safe in an allocator. A debug-only `--memory-cap` makes the cap small for tests. If wrong, the pane
  would say only that the REPL ended.
- 2026-11-09: `(buffer/new 1e12)` is not the memory fixture (work-queue best guess, from the plan). Janet's integer
  check refuses it before it reaches the allocator. A fixture keeps it as an ordinary error. The memory fixtures ask
  for 2,000,000,000 bytes and grow a buffer without limit.
- 2026-11-09: A form stuck in a C call is a read of standard input in the fixtures (work-queue best guess). The plan
  named a long `peg/match`, but Janet 1.43's PEG checks the interrupt flag. A read waits in one C call and has no
  deadline of its own. If wrong, any other C call that never checks the flag would do.
- 2026-11-09: The app-wide budget refusal is `admitRepl`, which adds up the footprints the last look read (work-queue
  best guess). A look every second leaves the total up to a second stale, which the text's own overshoot of one cap
  already allows. The pane posts one warning for each refusal episode, and a successful start ends the episode. If
  wrong, a fresh read at each start would put a system call on the main actor.
- 2026-11-09: The REPL footprint is 3.2 MiB at rest and the attach takes about 22 ms (work-queue best guess, a
  measurement). The figures are in M5's As built block, Debug builds only.

- 2026-11-09: A late stop request is always a no-op (work-queue best guess, from the M5 review). The REPL put the old
  SIGINT disposition back before it detached, and the watchdog thread lives on until the process ends, so a request
  that slipped in then hit the default action. The handler now stays installed and does nothing once the form is
  over, in a run and in a REPL. If wrong, the old disposition could return once the watchdog has stopped.
- 2026-11-09: The allocator's failure path sends no formatted text and flushes no stdio (work-queue best guess, from the
  M5 review). The message is built when the cap is set. A flush is stdio, so unflushed output at the cap is lost, as
  it already may be when the app quits. The notice goes through a hook that takes the connection's own send lock,
  which the watchdog's pong shares, so the two never interleave. If wrong, the watchdog could send the notice, with
  the VM thread waiting for it.
- 2026-11-09: One warning for each over-budget episode, kept by the host (work-queue best guess, from the M5 review).
  The first build kept one for each pane, so several panes refused together warned several times. The first refusal
  announces, and the episode ends when an admission or a look finds the total back under the budget. If wrong, the
  warning would be one for each pane again.
- 2026-11-09: Admission reads fresh footprints and counts an unattached helper at a floor (work-queue best guess, from
  the M5 review). Amended "Where scripts run", whose text said the total overshoots by at most one cap. A helper that
  attached after the last look read as nothing, so a burst of REPLs could pass the budget by more. The reads are one
  `proc_pid_rusage` each, which ADR-08 allows on the main thread. The floor is 8 MiB. The guarantee is now that the
  total at admission is at most the budget, and one admission adds at most one cap beyond it. If wrong, a look
  before each admission would put an await in the start path.
- 2026-11-09: The listener requires a declared role before any call, refuses a second declaration, and bounds the
  declaration to the same 5 seconds as the hello (work-queue best guess, from the row review). M2's As built said a
  peer has 5 seconds to say hello, and the timeout was cleared after it. A peer could then call with no `begin` or
  `attach`, begin again after calling to rename its session, or hold one of the 32 slots forever by saying nothing
  more. The 5 seconds now run from connecting to declaring. A declared peer has no bound. If wrong, a peer would need
  no declaration before a call, as before.
- 2026-11-09: A run blocks SIGINT on every thread but the VM's, as a REPL does (work-queue best guess, from the row
  review). Amended "Sandboxing". The text said both modes end in one handler on the VM's own thread, but a run left
  SIGINT unblocked on the watchdog thread, so the process-directed signal could land there and the gate and the count
  were not kept by one thread. If wrong, the handler would need atomics that tolerate two threads.
- 2026-11-09: A pty exit that reaches the pane before the helper's memory-limit notice no longer hides the reason
  (work-queue best guess, from the row review). The pane ended the channel on the exit and dropped the later notice,
  so it said only that the REPL ended. It now keeps the channel until the connection closes, and a reason that arrives
  meanwhile replaces the generic message. If wrong, the pane would say only that the REPL ended whenever the exit
  came first.

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, APPLET-9
- Coding standards: `languages/janet.md` and `languages/lisp-embedding.md`
- ADR-02: pane tree nodes have stable IDs
- ADR-07 (proposed): Failure Isolation. A failure ends only what failed
- ADR-08 (proposed): UI Responsiveness. The UI never waits on unbounded work
