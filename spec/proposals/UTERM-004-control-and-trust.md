# UTERM-004: Pane Control and Trust

**Status:** implemented
**Created:** 2026-10-31
**Updated:** 2026-11-20

## Dependencies

- UTERM-001
- UTERM-003

## Impacts

- UTERM-005, UTERM-006, UTERM-007, UTERM-008, UTERM-009, UTERM-010 — "Control levels": each applet declares which
  access-mode and driver combinations it supports
- UTERM-001 — "What layout persistence restores": saved layouts record inactive control intent, never grants
- UTERM-003 — "Sandboxing", "Host API", and "REPL features": this proposal supplies fresh-helper capability grants,
  scoped discovery, authenticated pane binding, and the `uniterm/send-command` host function. Its M1-M2 replace broad
  same-user control when they land. "Verified artifact and run binding" signs the `uniterm` command with the hardened
  runtime and one entitlement, for unsigned executable memory, so `--allow ffi-jit` still runs JIT code. A debug
  build's command can no longer take a debugger. `--allow modules` loads no native module before or after, since the
  vendored Janet is built without dynamic modules. Amended 2026-11-11; see Decision Log.
- UTERM-005 through UTERM-010 — exec schemas and supported combinations stay with each applet's design; this
  proposal supplies the shared transport and tests it with presentation fixtures

## Summary

Programs and scripts can drive panes. This proposal defines who may control which pane, and how. Controller approvals
can last for one operation, one run, one verified version, or a signing identity across versions. It covers two
access modes, remote-controlled and disconnected, and an independent exec driver. It also lets a program request a
layout for the panes it owns.

## Motivation

The write-up's best ideas need panes that talk to each other. One example is telling the nearest browser pane to open a
page. Another is a presentation program showing slides, notes, and charts in separate panes. Each needs rules, so that
one program cannot take over panes it has no business touching.

## Design Decisions (Settled)

### Control modes and exec drivers

- **Remote-controlled (CONTROL-1).** Other programs may drive the pane, within the trust rules. The pane shows a visible
  marker, such as a robot icon.
- **Disconnected (CONTROL-2).** Other programs cannot address the applet through remote control. Host lifecycle
  events and the user's own actions still work.
- **Exec (CONTROL-3).** Independently of access mode, the applet can attach a program as its driver. Applet events go to
  the program's stdin. Its stdout drives the applet. Its stderr goes to the window history as info-level diagnostic text
  and takes no turn on the status bar. The host sanitizes, coalesces, and bounds it before the main-thread queue admits
  it. A driver exit or protocol failure that the host observes is a separate typed warning, or an error when user work
  is lost. Level never comes from matching words in stderr. The attached driver is not an ambient remote caller, so
  disconnected does not sever this explicitly attached channel. Amended 2026-11-06; see Decision Log.

Each applet declares which access-mode and driver combinations it supports. Unsupported combinations are refused
before anything starts. Window shortcuts reach uniterm before applet events reach a driver, per ADR-04.

Amended 2026-11-02; see "Is exec a control level?" and the Decision Log.

### How uniterm knows which pane a program runs in

Original question: how uniterm knows which pane a program runs in. Options were an environment variable, process
ancestry, or a per-tab socket or file descriptor passed to the shell.

Decision: use the peer identity on UTERM-003's listener and validate its live process ancestry against an explicitly
recorded terminal session root. A pane token is not authority.

- TerminalSurface supplies the actual spawned child's process identity, including its generation. Its protocol grows
  a typed identity event, `TerminalEvent.processStarted`. The pinned libghostty backend needs a narrow patch to
  expose the child. ThirdParty/ghostty-patches/001-child-started-action.patch adds a `child_started` action that
  carries the child's PID. libghostty's public API does expose `ghostty_surface_foreground_pid`, but that is the
  pty's foreground process group, not the spawned child. No other module reaches through the terminal boundary.
  libghostty queues each surface's events for the main thread by the surface's address, and the allocator gives a
  freed surface's address to the next surface. ThirdParty/ghostty-patches/002-surface-message-identity.patch tags
  each queued event with the surface's unique ID, so a closed session's queued exit never reaches the session that
  replaced it. Amended 2026-11-11; see Decision Log.
- The spawned child is setuid-root `/usr/bin/login`, which becomes the session root. `proc_pidinfo` refuses a root
  process for a non-root caller, so ProcessInspection reads start times and parents with sysctl(KERN_PROC_PID). The
  listener reads the peer's uid with LOCAL_PEERCRED and its PID with LOCAL_PEERPID.
- Each connection is bound to the authenticated peer process instance, the source tab/session, and UTERM-003's
  launch-scoped window and pane references. A reused PID is a different instance, and so is a process after a
  successful exec. The instance is the PID with the process ID version from the peer's audit token, which the kernel
  changes on exec and on PID reuse. A peer whose token cannot be read is refused at the listener. Check the live
  identity and ancestry before granting automatic authority and before dispatch. An unavailable, changed, or ambiguous
  chain fails closed. Amended 2026-11-11; see Decision Log.
- App-created REPL and exec processes bind through the same recorded spawn identity. UTERM-003's REPL environment
  token may correlate a pending connection, but never grants authority without the process check.
- An unbound caller has no pane access. The user can explicitly grant that connection a named source pane in one
  window. The dialog names the requesting executable and scope. A grant binds to the pane's session. A pane with
  several tabs runs several sessions, and the grant binds to the newest one still running. A grant ends on disconnect,
  process exit, source session close, revocation, or window close. A denied or revoked connection is not asked about
  again. A reconnect needs fresh admission; verified controller policies may supply its permissions. An ordinary
  unbound caller asks again. An outside caller never receives every window.
- Ordinary descendants of a terminal session may act for that source pane. A daemon that loses its ancestry needs an
  explicit grant. Focus, a claimed PID, environment state, and a tty name never establish authority.
- This is application authorization, not an OS sandbox against malicious processes of the same user. Deliberate
  socket transfer, terminal-device injection, or process injection can relay another process's authority. Such work
  needs OS isolation to be a security boundary. The risks state this limitation.

Rationale: ancestry establishes pane provenance without a copyable bearer secret. An inherited descriptor instead
establishes delegable possession. Asking on every normal connection leaves automatic identification undone. The
explicit-grant fallback handles callers whose provenance cannot be established without guessing.

### Is exec a control level?

Original question: the write-up notes that exec might be a separate dimension from control. Options: one level among
three, or a separate setting that combines with the others.

Decision: access mode and driver are independent, as "Control modes and exec drivers" defines. An exec driver and an
authorized remote caller use the same command validation and serialized dispatch. A disconnected pane keeps its
attached driver and refuses ambient ingress.

Rationale: selecting a program to drive events says nothing about which other programs may address that pane. Three
exclusive states conflate those two contracts. Three presets backed by two dimensions would still omit the supported
remote-plus-exec combination.

### Trust follows the pane tree

A program may address its own source pane and panes in groups it explicitly owns. Geometry alone grants nothing.
It is not trusted with ancestors or unrelated siblings. Every operation also checks the target's access mode and
supported commands.

Rationale: the presentation program owns its explicitly created subtree and may lay it out. Normalized split-tree
shape cannot represent that authority. Amended 2026-11-02; see "What anchors trust" and the Decision Log.

### Same window only

Superseded in part by UTERM-026; see Decision Log.

A program may control panes only in its own window.

### Layout requests

Superseded in part by UTERM-026; see Decision Log.

A trusted program may request a layout for its own subtree. For example, it may ask for three panes holding a slide, a
set of notes, and a chart.

- A script asks with `uniterm/request-layout`, and an exec driver with a `layout` message. Both send one JSON layout.
  Its nodes are a split with two or more children, a pane already open, or a new pane. A new pane names its applet
  kind, and may name its access mode, a directory, and an exec declaration. Any node may take a relative weight. A
  layout holds at most 16 panes and 6 levels of splits. The reply names the pane at each leaf, in order.
- The request is anchored at a pane the program may address. A driver's anchor is its own pane, which must be
  remote-controlled. Every pane already open that the layout places must be remote-controlled too.
- A program has at most one layout in preparation. Another one is refused as busy before anything is built.
- The script call takes ScriptWire version 7. Both sides refuse any other version at the hello, so an old `uniterm`
  command with a new app, or a new command with an old app, runs no call. The driver message, and a driver's commands to
  the members it owns, take exec protocol version 2. Each side refuses any other version at the hello, so an old driver
  with a new app, or a new driver with an old app, runs no command. No deploy order is needed.

Amended 2026-11-11; see Decision Log.

### Group node kind

This proposal defines a group node kind for UTERM-001's pane tree. A program's first pane request creates a group, and a
layout request creates one too. The group records its owner and never merges into its parent. UTERM-001's pane tree
lets a node kind define its own merge rule. Its layout file bumps the schema version for a new node kind, to version 2.
M2 builds the group and its saved form, since its checks need owned members. M4 builds layout requests on it. The
details are part of "What anchors trust" below. Amended 2026-11-10; see Decision Log.

### What anchors trust

Superseded in part by UTERM-026; see Decision Log.

Original question, raised by the UTERM-001 review on 2026-10-31. The settled "Trust follows the pane tree" reads trust
from tree shape.
UTERM-001 settled a normalized N-ary pane tree. In it, a leaf pane has nothing beneath it. A program's requested
subtree can also merge into a same-axis parent. And a user split can put new panes under a program's pane. Trust
likely needs an explicit owner mark that a layout request creates, with a grouping node kind that does not merge. This
may revise the settled decision.

Context from UTERM-001's implementation, in support of an ADR candidate on ID scope:

- Node IDs are unique only within one window, and a trust grant keyed by ID must carry the window too.
- A pane reopened by undo gets a new ID, so a grant keyed by ID does not follow it.

Decision: explicit ownership and membership anchored by a nonmerging group, never ordinary split-tree shape.

- A group's owner is a live connection bound to its source process and session. Group and pane IDs carry UTERM-003's
  launch-scoped window reference. A group never merges or collapses into its parent, including with one child. A
  group left with no member is removed and its ID retires. The source pane is placement metadata, not a member.
- The first layout wraps only the source pane and newly created panes. It preserves the source pane and applet.
  Later requests rearrange only still-owned members and create new ones. They cannot import unrelated panes,
  replace existing applets, or silently discard members. A later request places every pane of its group once. It is
  refused while the group holds a pane that is neither its source nor a member, such as one the user split off or
  another controller's nested group.
- Nested layouts create explicit nested groups. Authority intersects the live connection's grant, window, explicit
  membership, target access mode, and supported operation at dispatch. Children gain no authority over parents or
  siblings by being nested. An ancestor owner retains only its existing explicit scope.
- User splits create panes outside the owned group boundary. A user split of a member puts the new pane beside it,
  inside the group's area but not among its members. A user move cannot add a pane to program ownership. Removing a
  pane from a group removes that group's authority over it. A new move UI is not required here.
- Disconnect, process exit, source-session close, window close, or user revocation removes the owner's authority.
  Group and content remain visible with no live owner. Another process cannot claim them by presenting their IDs.
  An attached exec driver retains only its explicitly attached channel, subject to its own lifetime.
- Scope checks apply to discovery and reads as well as mutations. Callers cannot list unrelated windows or pane
  metadata. Stale and out-of-scope references return no target data. Programs cannot enable control on existing
  disconnected panes. The user can revoke through pane chrome independently of applet content.
- Layout requests stage and validate a candidate tree and applet preparation, then revalidate authority at publication.
  Invalid references, unsupported combinations, insufficient space, or preparation failure publish nothing. Existing
  applet identities and content stay intact. External process effects cannot roll back: approved programs start only
  after the tree commits. A later launch failure reports in its pane without automatic retry or a claim of rollback.

Rationale: per-pane marks alone do not delimit structural edits. The wrapper preserves the boundary through
normalization. Explicit membership prevents unrelated user panes from gaining an owner by changing position. Amended
2026-11-11; see Decision Log.

### Exec wire format

Superseded in part by UTERM-028; see Decision Log.

Original questions:

- The message format on stdin and stdout, such as JSON lines.
- How each applet documents its events and commands.

Decision: UTF-8 JSON objects, one per LF-terminated line, on separate stdin and stdout pipes. Newlines inside strings
are escaped. Stdout carries protocol only; stderr carries diagnostic text.

- Both sides exchange hello messages with protocol version, applet type, and command/event schema version. No applet
  commands or user events flow until both versions are supported. Old driver/new app and new driver/old app refuse
  unsupported versions before effects, with an actionable error. In-place updates need no deployment order. Remote
  host calls retain UTERM-003's handshake and use the same command validation.
- Envelopes distinguish events, commands, successful replies, and structured errors. Request IDs correlate replies.
  Commands execute in order through shared serialized dispatch. Each applet publishes supported combinations,
  schemas, versions, and examples. Unknown commands and invalid arguments return errors without applet effects.
- A frame is at most 1 MiB. Retained queued bytes are at most 4 MiB per driver in each direction. Parsing also bounds
  nesting, decoded memory, and work per UI turn. A driver exceeding a bound fails visibly; commands are never silently
  dropped. A malformed frame or partial frame at EOF closes the channel. A stalled reader cannot block the UI or
  grow an unbounded queue. Limits apply before a complete line has been buffered. A typed clipboard read or write
  carries at most 128 KiB of text. JSON escapes a control character to six bytes. The bound is an eighth of a frame,
  so a text at the bound always fits one frame. A longer text is never cut. A read of a longer clipboard is refused
  as that one call. So is a longer write whose line fits a frame, and the channel stays up. A line past the frame
  still ends the driver, since the reader refuses it before it learns the request ID. The script wire's bound is 32
  KiB, half of its largest message body. It sends text unescaped in a binary frame.
- The applet owns a separate direct-argv child and its streams. Terminal program mode's pty cannot supply this
  protocol. Lifecycle events remain ADR-05's: the applet starts and cleans up its work. Close ends authority at once
  and shuts the child down asynchronously. Exit or protocol failure leaves the pane with a reason and an explicit
  restart action. There is no automatic restart.
- Stderr is drained with bounded retained text, sanitized and coalesced into source-labelled status messages. It
  cannot flood the main thread or masquerade as a host message.
- Terminal and REPL input injection remains unavailable, as UTERM-003 settles. An applet without an appropriate
  command schema or exec support refuses before launch.
- The applet contract gains one command and event hook, which this proposal adds. Shared dispatch delivers each
  validated command to the target applet through it, and the applet emits its events through it to its exec driver.
  An applet publishes its command and event schemas and their versions through the same member. Events emitted with no
  exec driver attached go nowhere and are not queued.
- Supported combinations are declared separately from commands, by every applet. An applet that declares nothing
  supports disconnected access with no exec driver. The terminal and REPL applets declare disconnected and
  remote-controlled access with no exec driver and no commands, as "Clipboard access from controlled panes" and M2
  assume.
- A remote host call carries one applet command to a target pane, with its reply or structured error. It uses
  UTERM-003's handshake and the same authorization, validation, and serialized dispatch as an exec driver's commands.
  Its authority is the caller's own grant, never an attached driver's channel. In UTERM-003's Janet module it is
  `uniterm/send-command`, following that module's verb-noun naming. Remote callers receive no applet events.
- Each remote command names the applet type and the command schema version it was written for. An unsupported type or
  version is refused before any effect, as the exec hello refuses. Skew: an old script or controller against a new
  app, and a new one against an old app, are both refused when the app does not support the named version. No deploy
  order is needed.
- A driver may lay out its own subtree, as "Layout requests" describes. It may also command a remote-controlled member
  of a group its run owns. Such a command names the pane, the applet type, and the schema version, as a remote command
  does. Its authority is checked again at delivery. A driver's group loses its owner when the run ends or the user
  revokes it. Revoking leaves the driver its own attached channel. For the rest of that run, it lays out and commands
  nothing beyond its own pane.

Amended 2026-11-12; see the Decision Log.

Rationale: JSON already serves the applet boundary and is easy for external drivers. CBOR can be equally correct,
but brings another serialization ecosystem without a stated need. Unversioned text leaves old commands liable to new
meanings. The applet schemas define semantics; JSON syntax alone does not.

### Clipboard access from controlled panes

Original question and context from UTERM-001. A terminal program's OSC 52 clipboard read asks the user, in a dialog
that names the pane. A write goes through without asking. The generated config sets `clipboard-write` to `ask`, and the
terminal surface allows every OSC 52 write that libghostty sends it. It denies every Kitty clipboard protocol read and
write. So a program in a remote-controlled or exec pane can replace the clipboard silently. Decide whether a control
level changes either rule. A write prompt would go in the surface's write callback, where an OSC 52 write arrives with
libghostty's confirm flag set. An ADR candidate on clipboard trust in UTERM-001's Decision Log may be shaped by this
decision.

Decision: remote-controlled and exec-driven panes require explicit permission for programmatic clipboard reads and
writes. A valid scoped approval can cover repeated requests. Attributable controller requests use the typed clipboard
API; shared-terminal OSC 52 offers only once/session permission for programs in that terminal session. A control grant
alone grants neither clipboard power. Amended 2026-11-07; see the Decision Log.

- Ordinary disconnected interactive terminals keep their existing read-ask, write-allow policy. Direct user Copy and
  Paste retain current rules. An attached exec driver triggers the controlled policy even when disconnected.
- TerminalSurface receives clipboard policy explicitly per session. The confirm callback enforces it for reads. The
  write callback enforces it for OSC 52 writes, which arrive there with libghostty's confirm flag set. Kitty clipboard
  requests stay denied in the confirm callback. Updating an existing session's policy completes before enabling
  ingress or an exec driver. A host-dispatch check alone cannot govern OSC 52.
- Answers revalidate the request's session, mode, and authority generation. Stale requests are denied. A denied read
  sends no data; a denied write leaves the clipboard untouched.

Rationale: a pane-scoped grant does not authorize silently replacing a global clipboard. Confirmation keeps deliberate
tmux, vim, and ssh workflows available. Denying all controlled clipboard use removes those workflows.

### REPL capabilities and host-side execution

Original question: UTERM-003 defers how a REPL receives Janet sandbox capabilities until this proposal settles control
modes. Decide how the user grants them, and how a layout or exec request avoids bypassing a helper's denied process
capability.

Decision: only a local user action starts or restarts a REPL with explicitly selected Janet capability names. The
fresh helper shows its grants. The default is none. Restart warns that live VM definitions will be lost; a live
sandbox is never widened. Revocation ends that helper and its pane authority. Grants are tied to that helper's
process generation, never inherited through pane ownership or restored from a layout. UTERM-003's explicit
`uniterm run --allow` behavior stays.

Host-side exec and program-mode launches need separate execution authority. A scoped grant can cover repeated
launches of named packaged entries with varying inputs. Without one, a local Allow once approval binds immutable
argv, directory, environment, and live target. Pane control and a helper's runtime process capability never imply host
execution permission. Scripts cannot activate Run or approve their own requests. Ordinary interactive-shell restore
remains ADR-03's exception. Approved programs are not claimed to be OS-sandboxed by this policy.

Amended 2026-11-02; see "Permission scopes and approval flow".

Rationale: pane ownership, runtime capabilities, and executing a host-side program are distinct permissions. Equating
them lets a script bypass its denied process capability through a layout request. Keeping every REPL unprivileged
would leave the deferred in-pane grant workflow unavailable.

### How control is enabled

Superseded in part by UTERM-028; see Decision Log.

Decide the defaults for user-created and program-created panes, who changes modes, and what a caller may request
when its source pane is disconnected.

Decision: user-created panes start disconnected with no exec driver. A local pane-chrome action enables remote
control. It never follows focus or a neighboring pane's mode. Identity alone permits no target metadata, applet
commands, or rearrangement of a disconnected pane. A connection can obtain only its own binding information and an
error explaining the local enable action. Ordinary denied calls do not open enable dialogs.

Once enabled, a source program may explicitly create remote-controlled panes in its owned group. Creation and
ownership authorize that mode on new panes; enabling an existing disconnected pane remains user-only. A program launch
still needs the separate execution authority in "REPL capabilities and host-side execution".

Disconnecting a target invalidates queued ambient calls to it before the action returns. Revoking a controller ends
its live grant, including queued calls and owned-group authority. These are distinct actions: a disconnected source
may still issue outbound calls to other targets it already owns, but cannot rearrange its disconnected source pane.
Pane chrome shows mode, owner, and driver, and exposes enable, disconnect, and revoke without relying on applet input.

Rationale: remote-by-default grants ordinary descendants authority before consent. Prompting on the first denied call
lets untrusted traffic create unsolicited dialogs. Local enablement separates provenance from permission.

### Exec launch context

Original question: how exec argv, working directory, and environment are supplied without hidden inheritance from
uniterm or a neighbor pane.

Decision: a declaration supplies literal argv with an absolute executable path, an optional absolute working directory,
and an explicit environment map. No shell interprets argv. Missing directory means the user's home. The base
environment contains only HOME, USER, LOGNAME, and TMPDIR from the OS user/session, plus
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Extra variables come only from the explicit map. Nothing comes implicitly from
uniterm's environment or another applet's directory.

An Allow once launch approval shows and binds resolved argv, directory, and environment overrides. A reusable scoped
approval instead covers the declared entry and its allowed directory and environment-key scopes; runtime values may
vary within them. Environment values remain runtime-only: layouts retain required key names, never values. A restored
Run action waits for those values and current execution authority, which a matching policy can supply. The user must
still choose Run. Command and directory remain inert saved state. Amended 2026-11-02; the explicit context and defaults
are unchanged.

Rationale: full inheritance can leak credentials and makes identical declarations behave differently depending on
how uniterm launched. Requiring every ordinary OS variable individually adds friction without removing a further
state dependency. The documented base is explicit. CLAUDE.md requires the user to confirm this choice at the gate.

### "Nearest" pane

- How "the nearest browser pane" is defined: closest in the tree, most recently focused, or explicit.
- What happens when no such pane exists: fail, or open one.

Decision: filter to authorized remote-enabled targets of the requested applet type in the caller's window first.
Rank by shortest edge distance from the source pane in the current normalized pane tree, treating group wrappers as
transparent. Break ties by reading order, then stable pane ID. This is tree distance, not physical screen distance.
Explicit references remain available when the caller needs a fixed target. A script names a nearest target as
`{:nearest kind}` wherever a pane reference goes, and the caller's own pane counts as a candidate. Amended 2026-11-10;
see Decision Log.

Resolve and revalidate at dispatch. No match returns a structured not-found error. It never falls back to an
unauthorized pane or creates one implicitly. Creating a pane or layout is a separate explicit request.

Rationale: focus-based selection changes with unrelated user activity. Explicit references alone leave the requested
convenience unavailable. Filtering before ranking prevents proximity from becoming authority.

### Saved layouts

Original questions:

- How a program's requested layout is remembered and restored.
- Whether a restored layout keeps its trust, or asks again.

Context from UTERM-001: the layout file stores each window's tree with its node IDs and a per-window ID high-water
mark. Windows are stored by order only, with no saved identity. A description this build cannot read round-trips
byte-for-byte. A new node kind, such as the group, bumps the schema version, and an older build moves a newer file
aside.

Decision: save layout intent, never live authority.

- Save group structure, geometry, source/member node IDs as inert placement metadata, desired access/driver modes,
  and applet descriptions. An exec declaration saves argv, directory, and required environment key names only.
  Connections, process generations, live owners, live grants, sandbox capabilities, and environment values are not
  saved in the layout. Durable controller policies live separately.
- Relaunch and undo have no active owner or ambient control. Effective access starts disconnected; saved desired
  modes are shown as inactive intent. Exec runs nothing until a local Run action and current execution authority.
  A matching verified policy can provide that authority without another permission dialog. A restored REPL starts with
  no capabilities. Undo's new pane ID never inherits an old grant, even within a surviving group.
- The user may explicitly grant a new live connection the exact restored member set through pane chrome and enable
  the desired targets. The grant binds current identities, not historical process names or file claims. A new exec
  attachment alone grants no ownership of restored siblings. Reopened panes stay unowned until explicitly assigned.
- The group and host-owned mode/driver metadata bump the envelope schema version. M2's group and saved control took
  it to version 2, and M3's exec declaration takes it to version 3. Old layouts migrate to no grants and disconnected
  modes. Applet payloads keep their own versions and unreadable bytes, per ADR-06. A corrupt group
  or cross-window membership can never enlarge a grant.
- Stored-data skew follows ADR-06: a new app upgrades an old envelope step by step. An old app keeps a newer file aside
  unchanged and starts a default layout. A downgrade then upgrade can lose the active newer arrangement; the kept
  copy remains available for manual recovery. No new deployment gate is needed.

Rationale: restoring geometry should not let a different process inherit a former program's authority. Dropping
program-created layouts entirely loses the requested remembered arrangement. Inert intent keeps both properties.
Amended 2026-11-11; see Decision Log.

### Controller trust and approval choices

Original question: how to avoid repeated permission interruptions while knowing which controller requests access.
The user chose a common framework for binary and script controllers, including optional persistent identity trust.

A controller description has a stable controller ID, display name, binary or script entry, packaged code and
dependency digests, and declared typed permissions. The display name is not proof of identity. Script identity never
comes from trusting the shared interpreter or Janet helper.

Approval choices:

- Allow once: the pending operation only.
- Allow for this session: the requested permissions for the current authenticated controller run.
- Trust this version: remember approval for this exact verified artifact, including packaged code and dependencies.
- Trust this identity: remember approval for the signing key and controller ID across correctly signed versions.

Signing is optional. Unsigned controllers can receive version trust. Local signing keys and signing tooling do not
require a paid Apple developer certificate or installation of a system-wide trusted root. Key continuity identifies
an approved signer, not a verified real-world person. A new signing key needs approval.

A durable approval records its identity or version selector and normalized, typed permission scopes. A startup request
covered by that approval proceeds without another dialog, including a narrower request. New powers or broader scope
need one review showing the difference. Runtime capabilities, clipboard reads, clipboard writes, host launches, and
pane-control authority remain separate permissions. Undeclared effects are refused. Semantic permission containment and
verified-artifact-to-run binding are required; a client cannot assert its own approved script name or digest.

Approvals live outside layout state. Controllers & Permissions provides inspection and revocation. Each run creates a
fresh authenticated process/connection binding and current pane/group scope. Saved approval cannot restore an old
connection or adopt arbitrary restored panes. Layout restore still runs no controller automatically.

Rationale: users can approve a useful stretch of work and remember trusted controllers without repetitive dialogs.
Version trust supports unsigned tools; identity trust preserves approval across signed updates. Neither is blanket
trust in every script run by a shared interpreter. Amended 2026-11-02; replaces the earlier run-only consent direction.

### Permission scopes and approval flow

Superseded in part by UTERM-032; see Decision Log.

Original question: integrate startup declarations and remembered approvals with clipboard attribution, host-launch
scopes, control enablement, REPL capabilities, revocation, and inert restore without repeated modal interruptions.

Decision: approve typed authority ceilings, rather than exact launch inputs. A controller declares its requested
powers once at startup. Normalize permissions and compare their semantic version and scopes against the approval.
An unchanged or narrower request is covered. An unknown permission meaning, additional power, or broader scope
requires a local review before effects. Undeclared effects fail even when the controller's identity is trusted.

- A host-launch grant names packaged entry IDs, current owned-group targets, allowed environment keys, and permitted
  directory scope. The approval explicitly says that arguments and environment values may vary within these bounds.
  Values remain runtime inputs and are not saved as approval secrets. Another executable/entry or broader scope needs
  approval. Arbitrary host-program execution is not implied by permission to launch a declared packaged entry.
  A controller declares a host launch in its descriptor: an absolute executable, a directory that covers itself and
  every folder inside it, and environment key names. Its target is any pane of a group the live run owns. The user's
  Run starts such a launch with no question while the run's own approval holds the scope. The launch's folder and
  the approved one are compared with every link resolved, and the driver starts in the resolved folder, so a link
  inside the approved folder cannot lead the driver out of it. A folder that does not exist is not covered. Allow
  once holds none, so each of its launches asks. A launch with no owning run, such as a restored pane's, asks in the
  panel as before: Allow once, or a grant for that pane's exact executable and directory for this launch of uniterm.
  A launch waiting there in a pane of a group whose owner's authority ends is withdrawn. Amended 2026-11-12; see
  Decision Log.
- Allow once binds one identified pending effect and its immutable inputs. A session grant binds the authenticated
  live run. Version and identity policies can cover later freshly authenticated runs. A pathname, claimed digest,
  process name, or old pane ID cannot activate a remembered policy.
- Attributable controller clipboard reads and writes use new typed requests over the existing listener or exec
  channel. Each checks the live controller grant at the actual access boundary. Reads and writes are separate powers.
  Shared-terminal OSC 52 has no persistent script-specific attribution: it offers once/session terminal approval,
  honestly labelled as covering programs in that session. Ordinary disconnected interactive terminal behavior stays.
- Permission requests are bounded and coalesced into a host-owned pending indicator. The user opens the local panel;
  repeated protocol messages cannot spawn repeated modal dialogs. The indicator is the window's pending-permissions
  slot, a typed window state that sits before the focused applet's segments. Denial suppresses automatic re-prompting
  until a local retry. Coalescing cannot widen Allow once into approval of multiple different operations.
  Requests of one power from one requester share a row. A row holds at most 8 waiting operations, one requester at
  most 16 rows, and the panel at most 64. A request past a bound is refused as busy. A row shows its oldest waiting
  operation in full, which is the one Allow once releases. A denial outlives a reconnect: a controller run's covers
  its verified version, and an ordinary script's covers the scripts acting for its pane until the pane closes. A
  terminal tab's or a REPL's covers its kind of request under one control generation. Denials have no count bound.
  Each one is a user's Deny, and none is dropped to make room for another. Amended 2026-11-12; see Decision Log.
- A user's Run action supplies execution intent. A matching policy can supply permissions without a second dialog.
  Saved layout state alone never executes a controller. Remembered permission does not override an existing pane's
  disconnected mode or adopt restored group members. Source enablement and restored-member adoption remain local.
- REPL capabilities apply before a fresh VM starts, never by widening an existing sandbox. Mutable interactive REPL
  evaluations cannot borrow an approved packaged script's identity. Helper runtime capabilities, host execution,
  clipboard powers, and pane control remain separate dimensions.
- Durable policies live in a separate versioned private file, written atomically. Corrupt files and unknown policy
  semantics authorize nothing and are kept for recovery. Layout files contain no policy or signing key. Optional
  local signing keys are generic-password items in the login Keychain, each under a name the user gives. A missing
  key fails the signing, and no other key signs in its place. The policy file is
  `~/Library/Application Support/uniterm/controllers/policy.json`, format 1. A file this build cannot read is moved
  aside, numbered, and grants nothing. A file from a newer build, by its format or by a permission kind or version
  this build lacks, is left where it is, untouched, and this build neither trusts nor writes it. Controllers &
  Permissions shows trusted selector/fingerprint, approved scopes, and active runs. Revocation removes remembered
  policy and current authority, including queued work. A run whose admission a removal overlaps is reviewed, not
  started under the removed policy. It cannot undo external effects already performed by an approved program.
  Amended 2026-11-12; see Decision Log.
- Admission and typed clipboard contracts are versioned. Old controller/new app and new controller/old app refuse
  unsupported semantics before effects. The typed clipboard calls and the review notice take ScriptWire to version 9,
  and the driver's clipboard messages take the exec protocol to version 3. Each side refuses any other version at
  the hello. Permission scopes refer to current roles and owned groups, not persisted window or pane references.
  Amended 2026-11-12; see Decision Log.

Rationale: varying a chart's document argument does not request more authority. Exact-input matching would repeat
prompts despite unchanged powers. Identity trust alone must never authorize undeclared powers. The typed clipboard
API adds an attributable path; anonymous escape sequences cannot gain controller-specific persistent trust.

### Verified artifact and run binding

Original question: bind approval to verified packaged code and dependencies, without loading different bytes later or
mistaking an interpreter's identity for its script.

Decision: verify a completed private per-run snapshot and bind admission to its actual execution. Preserve the CLI-owned
Janet VM and existing listener; do not add a CLI terminal-I/O or signal relay.

- A small versioned descriptor lists controller ID, binary or Janet entry, packaged file digests, and declared
  permissions. Version trust covers descriptor and packaged code/dependencies. An optional signature covers the
  descriptor and its file digests; identity trust pins the signing public key plus controller ID. Signing and loading
  share one interpretation of the exact descriptor bytes. Unverified display metadata conveys no authority.
- The descriptor is `controller.json`, read as strict JSON, in format 1 or format 2. A repeated key, an unknown field,
  a value of another type, and anything after the document are refused. A packaged path is ASCII letters, digits,
  `.`, `_`, and `-`, in components that start with a letter or a digit, so no path has a second spelling. Two paths
  that differ only by case are refused. A controller cannot declare a capability that loads native code. A run's
  `--allow` names only declared capabilities. A run that does not declare pane control may post status and nothing
  else. Amended 2026-11-12; see Decision Log.
- Format 1 knows two permission kinds, with no version: `pane-control`, and a Janet `capability` by the name `--allow`
  takes. Any other kind is refused. Format 2 gives every permission a required `version`, those two kinds included.
  Each build knows a fixed set of (kind, version) pairs, each with one meaning, one review text, and the versions it
  covers. An unknown kind or version refuses the whole descriptor at load, and so does one kind listed twice. A kind
  that takes a scope, a capability's name or a host launch's executable, is listed once for each scope. Format 2
  adds `clipboard-read`, `clipboard-write`, and `host-launch` at version 1. A host launch names an absolute
  `executable`, a `directory`, and an `environment` list of key names. Approvals record (kind, version, scopes). A
  request covered by an approved version needs no new review, and a higher version needs one. A format 1 permission
  reads as version 1, so a format 1 approval covers the same kind at version 1 in format 2. Skew: a build without a
  kind or version refuses the descriptor at load, and a newer build reads older formats and versions with their own
  meanings. An older build reading a newer policy file authorizes nothing. Amended 2026-11-12; see Decision Log.
- The signature is `controller.sig`: an Ed25519 signature, through CryptoKit, over a fixed domain line and the
  descriptor's exact bytes. The version is the SHA-256 of those bytes, and the key's fingerprint is the SHA-256 of the
  public key. A signature file that does not verify refuses the package. It never falls back to an unsigned version.
- Copy to a fresh private snapshot, then verify its completed contents against the descriptor. Reject missing or
  unlisted code, escapes, symlinks, special files, and ambiguous paths or fields. Retain the read-only snapshot for
  the run. Ordinary edits or updates to the source cannot change later normal loading. User-owned read-only files
  are not OS-immutable against a malicious process of the same user.
- Managed script modules and native packaged libraries resolve only inside the snapshot. Uniterm's bundled runtime
  and standard library, and OS system libraries, are explicit platform exceptions. Runtime contract versions are part
  of approval semantics. Cwd searches, ambient module paths, startup hooks, and loader injection cannot select
  substitute dependencies. A Janet package loads only `.janet` source. Native modules and images have no loader, even
  inside the snapshot. For a native entry, what is checked is its load commands and those of every packaged library
  they reach: each library they name, and each search path, must be a packaged file or under `/usr/lib/` or
  `/System/Library/`, and none may carry an embedded dyld environment. Every packaged candidate an `@rpath` library
  could resolve to is checked, since dyld falls back past a system path that does not exist. Code the entry loads at
  run time with `dlopen` is not checked and can come from anywhere its privileges reach. An entry whose dependency
  boundary cannot be established is refused persistent admission; there is no silent downgrade of its guarantee.
  Amended 2026-11-11; see Decision Log.
- The bundle's command is signed with the hardened runtime and holds no get-task-allow. Its one entitlement is for
  unsigned executable memory, which `--allow ffi-jit` needs. On that command, dyld removes every `DYLD_` variable before
  any of its code runs, with no message, so neither the command nor the native entry it execs sees one. The app refuses
  a bundle command built otherwise. A command built without the hardened runtime, such as the package tests' helper,
  still sees a `DYLD_` variable. It refuses to start a run with an error that names it. `__XPC_DYLD_` variables are no
  loader variables: dyld never reads them, and a run proceeds with them set. Amended 2026-11-11; see Decision Log.
- Native entries start from the verified snapshot. Record the actual spawned executable's execution generation and
  code binding before granting authority. Janet's CLI remains the VM process: it owns stdin, stdout, stderr, working
  directory, arguments, signals, and exit status. Before user code runs, the app authenticates the bundle helper,
  independently verifies the artifact, and supplies its verified snapshot/run binding over the existing connection.
  The fixed helper loader evaluates only after admission and sandbox selection. No script output relay is added.
- A client-supplied digest or script path proves nothing. A foreign interpreter cannot borrow persistent script
  trust by claiming an approved artifact. The initial managed script loader is Janet. Other interpreters need an
  equally verifiable loader before receiving script-specific persistent trust. Generic peers retain explicit
  once/session admission without claiming such identity.
- Record artifact, entry, controller identity, approved scopes, peer execution generation, connection, source session,
  and current window/group. Execution generation includes successful exec, not merely PID and start time. Exit,
  executable replacement, disconnect, or revocation invalidates the live binding. It does not delete durable trust.
  Revalidate generation and revocation at dispatch, with exec/exit notifications for prompt invalidation.
- The run request is a `controller-begin` message, which ScriptWire version 8 added. It names the entry kind, the
  package path, and the requested capabilities, and no digest. The app answers with the snapshot's folder and the
  version it verified, or with a refusal. While the run waits for the user's review, the app first sends a notice
  that version 9 adds, and the command shows it. Both sides refuse any other version at the hello, so an old
  `uniterm` command with a new app, and a new command with an old app, run nothing. No deploy order is needed. The
  descriptor and signature formats start at 1. Amended 2026-11-12; see Decision Log.
- Unix-stream peer lookup is not immutable per-message sender attestation. Generation checks and notifications do
  not make check-and-effect atomic against exec or deliberately transferred sockets. Such races and injection remain
  within the stated same-user limitation. No atomic per-message or OS-sandbox guarantee is claimed.
- Verification identifies initial packaged execution, not arbitrary future behavior. Native dynamic loading or code
  interpreted from separately authorized filesystem/network input can exceed the initial artifact's contents.
  Managed import/image/native-module paths stay restricted; explicit runtime and OS privileges still permit a
  trusted program to interpret external input as code. Approval never asserts that future signed versions are benign.

Rationale: hashing an original path then reopening it leaves a replacement race. Trusting the helper alone fails to
identify its script. Verified snapshots and a fixed admission loader address ordinary substitution without changing
UTERM-003's CLI semantics. Moving every VM into the app would add relay and lifecycle obligations without a stronger
boundary under this threat model.

## Design Decisions (Open)

None.

## Risks

- **A process gains control of panes it should not** — likelihood: medium, impact: high.
  Mitigation: deny by default. Mark controlled panes visibly. Scope trust to the caller's subtree and window. Test
  denied cases. Revalidate live grants at effect dispatch and invalidate queued work on revoke.
- **The exec wire format becomes a contract external programs depend on** — likelihood: high, impact: medium.
  Mitigation: version the format from its first release.
- **Trust rules are too strict to be useful** — likelihood: medium, impact: medium.
  Mitigation: M4 exercises the presentation example through the real control transport and hosted slide, notes, and
  chart fixtures. Adjust any failure before M4 passes. Production applet support remains in each applet proposal.

- **Same-user processes can relay authority outside the pane model** — likelihood: medium, impact: high.
  Accepted: the control model is application authorization, not OS isolation. Descriptor transfer, terminal-device
  injection, or process injection can relay an authorized process's actions. No same-user security boundary is claimed.
  Mitigation within that boundary: no bearer-secret authority, live process checks, explicit target scope, visible
  owners, revocation, and separate local approval for host execution and controlled clipboard use.
- **The terminal backend identity extension changes with the Ghostty pin** — likelihood: medium, impact: medium.
  Mitigation: keep the narrow patch and its process-generation tests with the pin and cache identity. Unknown or
  unavailable identity denies automatic control and offers the explicit-grant path. No module bypasses TerminalSurface.
- **Applet and scripting designs are still in flight** — likelihood: medium, impact: medium.
  UTERM-003 is accepted but unimplemented. UTERM-005 through UTERM-010 may reshape their command schemas.
  Mitigation: use UTERM-003's single listener and references, validate shared contracts before M1, and keep each
  applet's schema and supported combinations in its proposal. M3-M4 use hosted fixtures, not assumed production APIs.
- **Saved intent or a downgrade is mistaken for live authority or a lossless restore** — likelihood: medium,
  impact: high. Mitigation: never put live grants, capabilities, or environment values in layouts. Store remembered
  controller approvals separately. Restore disconnected and bind live authority only after fresh admission and required
  local scope selection. Bump the envelope schema and preserve unknown applet bytes. Accepted:
  ADR-06's downgrade-then-upgrade layout loss remains; the kept-aside file permits manual recovery. Saved argv and
  directories remain private on disk, but can contain secrets, as terminal program declarations already can.
- **An explicitly approved program has the user's OS privileges** — likelihood: medium, impact: high.
  Accepted: exec programs and terminal programs are normal user programs, not sandboxed by pane authority. Local
  approval displays either immutable once-only inputs or the reusable authority ceiling and target scope. Runtime
  capabilities, control grants, and host execution approval remain separate. Mitigation: no implicit environment
  inheritance or host launch outside approved scope; no automatic retry; bounded protocol streams and asynchronous
  cleanup. The app cannot undo external side effects.

- **A remembered identity trusts future signed code** — likelihood: medium, impact: high.
  Accepted: identity trust deliberately delegates update continuity to the approved signing key and controller ID.
  A compromised key or malicious signed update can misuse already approved powers. Mitigation: offer exact-version
  trust, require review for broader permissions or a new key, show selectors in Controllers & Permissions, and revoke
  both active authority and remembered policy. No signature is presented as proof of harmless behavior.
- **Verification and actual loading diverge** — likelihood: medium, impact: high.
  Mitigation: verify the completed snapshot and actual run binding; use fixed packaged dependency resolution and
  explicit platform exceptions. M5 exercises source replacement, delayed imports, native libraries, helper identity,
  and executable generation changes. Accepted: OS/runtime privileges and deliberate same-user tampering exceed the
  initial packaged-code guarantee. Read-only snapshots are not an OS security boundary.
- **Policy or artifact formats gain a broader meaning in another version** — likelihood: medium, impact: high.
  Mitigation: version descriptor, admission, permission semantics, and policy storage. Unsupported meanings authorize
  nothing; corrupt/newer policy files remain recoverable. A downgrade never imports trust from layout state. Both
  controller/app protocol skew directions fail before effects. Compatible policy readers compare semantic scopes.
- **Permission requests become a source of interruption or misleading attribution** — likelihood: medium,
  impact: medium. Mitigation: one startup review, bounded host-owned pending UI, sticky denial, and no automatic modal
  flood. Typed controller clipboard access is attributable; OSC 52 remains honestly scoped to a terminal session.

## Milestones

### M1: Caller identity

**Status:** DONE

- uniterm identifies which window and pane a calling program runs in
- A call from outside any uniterm pane is rejected unless the user allows it
- TerminalSurface reports a real spawned process identity through a tested backend patch, never from caller claims
- PID reuse, a dead peer, inherited sockets after peer exit, ancestry loss, and closed source tabs grant no authority
- A stolen REPL environment token cannot bind a different process to that pane
- Live grants are scoped, revocable, and lost on reconnect; remembered policies require fresh verified admission
- Replacing or revoking a REPL helper invalidates its pending calls and grants
- REPL capability selection starts a fresh helper, warns about lost definitions, and restores no grants

**As built:**

- The Ghostty patch adds a `child_started` action that carries the PID of the child libghostty spawns.
  TerminalSurface reads the child's start time when the report arrives and reports both as
  `TerminalEvent.processStarted`. The fork has returned by then, so the read cannot miss a live child. A child that
  already exited gets no identity, so nothing binds to it. An earlier retry loop, left from diagnosing `proc_pidinfo`,
  was removed. In shell and program mode alike, the child is setuid-root `/usr/bin/login`, which becomes the session
  root. Two integration tests check that the reported PID is a direct child named `login` with the reported start
  time.
- Process records come from sysctl(KERN_PROC_PID), because `proc_pidinfo` refuses a root process. A PID that does not
  exist returns an empty record, and an exited process that its parent has not yet collected still has one. Both read
  as not running. The second was found and fixed in this milestone, with a regression test.
- Applets report each session's start and end to the window, the window set, and the script host. The script host
  alone keeps which pane each session root runs in. A closed window also tells the host, which forgets that window's
  roots and ends grants to its panes even when an applet never reported its end.
- Admission binds a connection to a recorded root through its peer's ancestry. Each call checks the peer's identity, the
  root's generation, and, for a binding found through ancestry, that the ancestry still leads to that root. A process
  whose parent exited loses its pane and asks like an outside program. A call that waits on a directory check is checked
  again after the wait and before the layout changes. An unbound call is refused, and the connection's request appears
  in the Pending Requests panel. A connection holds one request however many calls it makes. Requests are held per
  connection, and the listener holds at most 32 connections, so the list holds at most 32. A process that has exited
  cannot ask.
- The panel opens from Window > Pending Requests…, from the palette, and from a click on the pending-permissions slot.
  It lists waiting requests and live grants. Its grant sheet names the program and its PID, offers only panes with a
  running session, and names each way the grant ends.
  The pending-permissions slot shows in every window while any request waits. An outside caller has no window, so the
  slot is not per window. The slot shows how many of the panel's rows wait, such as "2 requests", and drops that text
  for its icon alone when the bar is too narrow. Each new waiting row also posts one line to the status bar.
- A grant ends on disconnect, process exit, the source session's end, revocation, and window close. A program that forks
  and exits does not pass its grant to the child that keeps its socket. A grant needs a waiting request and an unbound
  connection, so a bound connection cannot be moved to another pane. Grant scope for panes with tabs, and the end of
  asking after a denial or revocation, are best guesses; see the 2026-11-10 Decision Log entry.
- A REPL helper that attaches before the terminal reports its session root waits for the root, and is then checked
  against it. A token presented from outside the channel's session is refused before or after the root arrives. The
  earlier draft refused every attach that arrived first, which would fail a REPL whose helper outran the report. A
  call made while the attach waits is refused without asking the user, and a completed attach drops any request the
  connection left.
- Ending a REPL channel unbinds its helper's connection, so a call the helper sent but the host had not read never
  runs. A restart ends the old session in the host, so the old helper's binding fails too.
- Restart REPL with Capabilities… is in the REPL menu while a helper runs. Its sheet warns that definitions are lost
  and offers every capability `--allow` can grant, none selected. The fresh helper gets a new channel and token and
  only the chosen `--allow` flags. It prints the capabilities it may use. An unknown name ends the helper before it
  connects. The capabilities are not saved, and a later restart or a restored pane starts with none.
- A second Ghostty patch tags each queued surface event with the surface's unique ID. An integration test closes a
  session with its exit queued and checks the session that reuses its surface address. See the 2026-11-11 Decision
  Log entry on stale surface events.
- Package tests record the test process as a session root only through the ScriptTestSupport target, which the script
  host's tests and the REPL applet's tests share. Grant tests use a `sleep` process as the granted pane's session. The
  forked-and-exited and lost-ancestry cases use a small perl relay fixture, since a Swift test cannot fork. The process
  readers' tests sit in their own target beside the module. Two UI tests, for the panel and for the capability restart,
  compile and are run by the coordinator.

### M2: Remote-controlled and disconnected panes

**Status:** DONE

- The group node kind, open-pane's owned members, and layout envelope version 2 land here, ahead of M4's layout
  requests. Amended 2026-11-10; see Decision Log.
- A remote-controlled pane shows a visible marker
- Controlled clipboard policy covers background, newly opened, and reopened tabs before those sessions emit output
- New user panes start disconnected; enable and revoke remain accessible when applet content consumes input
- Clipboard policy is installed before a live mode transition enables remote ingress
- Disconnect rejects queued target calls; revoke also removes the controller's outgoing group authority
- A disconnected pane rejects ambient control calls while preserving its attached driver and host lifecycle events
- A program cannot control an ancestor or unrelated sibling; explicit owned group members remain eligible
- Nearest selection filters by authority first, uses tree distance and deterministic ties, and never creates on failure
- Each applet type's supported combinations are readable before a pane is created or a driver launches, and a type
  that declares none resolves to disconnected with no driver
- Controlled OSC 52 writes check once/session permission through real backend callbacks; denial changes nothing
- Pending clipboard approvals cannot release data or write after revocation, mode change, or session replacement

**As built:**

- The window holds each pane's access mode, keyed by pane ID, and issues it a new generation on every change. A pane
  with no entry is disconnected, so every new pane, and every pane reopened by undo, starts disconnected. The applet
  contract gained a hook that tells the applet its pane's control. The window calls it as the applet takes the pane,
  before it starts, and on every change. Enabling tells the applet first and records the mode after, with nothing
  suspended between.
- Enable Remote Control, Disconnect Pane, and Revoke Controller are pane commands in the File menu and the palette, with
  no key. They work while a sheet shows. There is no pane context menu, so the badge's own menu carries the same three
  actions. The badge is the `antenna.radiowaves.left.and.right` symbol in the pane's top right corner, since SF Symbols
  has no robot. It shows on a pane that is remote-controlled, owned, driven, in an unowned group, or restored with
  saved intent. Its tooltip and menu name the mode, the owner, every controller with authority over the pane, and the
  driver. The host reports each binding, grant, REPL attach, and end of one, and every window refreshes its badges.
  The menu also rebuilds from live state as it opens. Review found the badge's Revoke going stale while a controller
  bound by ancestry, and its test failed with the report's wiring removed.
- `AppletTypeDeclaration` carries the supported combinations. The terminal and the REPL declare remote control with no
  driver. Every other type declares nothing and resolves to disconnected. Open-pane checks the requested access against
  the kind's declaration before it checks the directory or builds anything.
- The group node never splices or collapses. Its content normalizes as a root, and members that are not panes of its
  content drop out. A group with no member dissolves into its parent. Tree distance counts split edges only, so a group
  is transparent. An owner's split extends the innermost group it owns that holds the target as source or member, and
  otherwise wraps the target in a new nested group.
- The layout envelope is version 2. The upgrade from version 1 keeps the windows list byte for byte. A group saves its
  source and members, never an owner. A pane saves its mode only when it is not disconnected. A damaged member list can
  only shrink a group, and a damaged or unknown mode reads as disconnected. A restored pane starts disconnected, and
  its badge shows the saved mode as inactive until the user acts on the pane.
- The host passes every call's caller, its connection and the pane it acts for, to the window layer. The window layer
  checks every target there, for lists, reads, and changes alike. A target out of scope answers as one that is not
  open. Revoke Controller ends every controller that acts from the pane or owns a group holding it. The host refuses
  the revoked connections' calls from then on, and every window releases their groups. A closed connection, an ended
  grant, a lost binding, and a closed source session release them too. The host API's rules, nearest targets, and the
  open-pane `:control` option are best guesses in the 2026-11-10 Decision Log entries. ScriptWire is at version 5.
- TerminalSurface takes a clipboard policy per session, at creation and on change. The write callback reads
  libghostty's confirm flag, so an OSC 52 write asks in a controlled session and a user's copy never asks. The prompt
  offers Deny, Allow Once, and a session button named for the tab. Session permission is kept per kind and ends with
  the policy. An answer counts only while the session is open and its policy is the one it was asked under. A session
  holds at most one waiting prompt per kind. A later read or write of that kind is denied at once and its text dropped,
  until M6's coalesced permission panel replaces this bound. Review found each OSC 52 write queuing its own sheet. The
  flood test saw 20 prompts for 20 writes before the bound, and 1 after. Both
  prompts now name the tab that asked, not the selected one. The window's and the terminal's naming tests failed with
  the fix reverted.
- Two new real-backend tests drive OSC 52 through libghostty's callbacks. With the policy check removed, the
  stale-answer test failed on both its read and its write. `PaneControlUITests` and the updated `ScriptRunUITests` and
  `ReplUITests` compile and are run by the coordinator. No layout codec fuzz target exists, so the codec changes have no
  fuzz run.

### M3: Exec panes

**Status:** DONE

- An exec pane starts a program and sends applet events to its stdin
- Hosted fixture applets receive validated commands and emit events through the applet contract's command and event
  hook, and an applet with no commands refuses every command
- Remote and exec commands share authorization, argument validation, and serialized dispatch
- Adding the remote applet-command call bumps UTERM-003's app-to-helper protocol version, so an old `uniterm` command
  with a new app, or the reverse, is refused at the handshake
- A remote caller, a Janet script through `uniterm/send-command` included, sends an applet command to an authorized
  target pane and receives its reply or structured error, with no effect on an error. A script gets the error as a
  Janet value, and the app never crashes
- A remote command naming an unsupported applet type or schema version is refused before any effect, for old and new
  callers alike
- A remote command to a disconnected pane is refused even while that pane's exec driver runs its own commands
- Authority is revalidated when the hook delivers a command, so a grant revoked after validation leaves no effect
- Events emitted with no exec driver attached reach no one and never grow a queue
- Terminal and REPL panes can still be made remote-controlled, and refuse every applet command
- The program's stdout drives the applet
- The program's stderr appears in the history as info, sanitized and coalesced, and takes no turn on the status bar. A
  driver exit or protocol failure is a typed warning or error, never a level guessed from stderr text. Amended
  2026-11-06; see Decision Log.
- Window shortcuts keep working while an exec driver is stalled
- Old/new protocol and applet schema mismatches in both directions execute no commands
- Stalled stdin, endless small stdout frames, malformed frames, and partial EOF stay bounded and fail visibly
- Child shutdown and stderr floods never block the UI
- Allow once binds immutable launch inputs; reusable grants enforce entry, directory, env-key, and live target scopes
- Varying arguments within an approved launch scope prompts nothing; a broader scope requires approval
- Scripts cannot approve their own permission requests or activate Run
- An exec child receives only the declared environment and documented base, in the declared or home directory
- Restored Run waits for required values and valid execution authority; layouts contain no environment values

**As built:**

- The applet contract gained the command and event hook as an opt-in protocol. An applet that adopts it publishes one
  command schema with its applet type and version, runs commands it receives already validated, and emits events
  through an outlet it owns. Only shared dispatch can make a validated command. An applet that does not adopt the
  hook refuses every command, and no shipped applet adopts it. The terminal and the REPL still declare remote control.
- Each window has one dispatcher, which remote callers and exec drivers share. It checks the caller's authority, then
  the applet type and schema version, then the command and its arguments against the schema. Only then does it queue
  the command. It delivers in order, 32 per main-thread turn, with at most 256 waiting, and refuses past that as busy.
  It checks authority again at delivery. A refused command is answered at once and changes nothing.
- `uniterm/send-command` takes a pane, an applet type, a schema version, a command, and optional arguments. The shim
  writes the arguments as JSON, at most 32 KiB, 16 levels, and 64 fields per object. A failure from the app raises a
  struct of `:kind` and `:message` in the script. ScriptWire is at version 6. It adds the call, an `unsupported`
  failure kind, a `reply-lost` kind, and a double value for numbers a Janet integer cannot hold. `reply-lost` means
  the command ran and its reply could not reach the script. Both sides refuse any other version at the hello, so an
  old `uniterm` command with a new app, or the reverse, runs no call. The remote path needs the target to be
  remote-controlled and in the caller's scope. At delivery it checks both again, and that the pane's control
  generation is the one the command was sent under, so a disconnect and a new enable drop queued commands.
- The exec driver is a new module. It spawns the argv directly with three pipes, in a process group of its own, in the
  declared directory or the home directory from the user database. The environment is HOME, USER, and LOGNAME from
  the user database, TMPDIR from the session's temporary folder, and the fixed PATH, with the declared values over
  them. It did not build on HelperProcess, whose spawn hands a helper one socket on a fixed descriptor and nothing on
  its standard streams. Reads, writes, and the wait each run on their own thread. Each pipe end takes FD_CLOEXEC right
  after its pipe is made. A channel whose applet has already closed spawns nothing and ends at once.
- The wire bounds are those the decision names. A line past 1 MiB is refused before it ends. Nesting past 32 levels or
  more than 65,536 values is refused before the JSON decoder sees the line. More than 4 MiB read and not yet handled,
  or written and not yet taken, closes the channel with a typed warning. The main thread handles 64 messages per
  turn. Events reach the driver only once both hellos are accepted. A hello mismatch in either direction tells the
  driver why and ends the channel before any command runs.
- Stderr goes through StatusKit's ingress to a producer named for the driver, as info in the history only. An exit or a
  failure is a warning through `post(failure:)`. Closing the pane ends the driver's authority at once. The applet's
  own close closes its outlet, which closes stdin, sends SIGTERM to the group, and sends SIGKILL two seconds later.
  The driver stays an unreaped zombie until its group has had SIGKILL, so a program it started in its group ends with
  it, however the driver ends. Nothing waits on the main thread, except at quit. There every group gets SIGTERM, one
  shared wait of at most half a second, then SIGKILL, since a delayed SIGKILL would never run after the app exits.
  The pane's strip shows the reason and Restart. Nothing restarts by itself.
- Run is a button in a host-owned strip at the foot of the pane. No script call or driver command reaches it. A
  driver with environment keys asks for their values in a sheet first, and keeps them only in memory. The launch then
  waits in the Pending Requests panel, which shows its argv, directory, environment values, and pane. Each argument
  and value is on its own line, with control characters and bidi controls escaped, so none can fake a line. Allow
  Once runs
  exactly those inputs once. Allow in This Pane makes the grant the Permission scopes decision describes for M3. The
  panel's buttons are the only way to decide a launch. The pending-permissions slot shows while a launch waits.
- The layout envelope is version 3. A pane's saved control holds its exec declaration: argv, directory, and key
  names. A damaged declaration reads as none. A restored or reopened exec pane shows Run and runs nothing.
- The slides, notes, and chart fixtures are a test-support target, with real schemas and events. A debug app links
  and registers them behind `UNITERM_TEST_APPLETS`. The fixtures' sources and the app's registration both compile
  only under DEBUG. That is verified at the object level: without DEBUG, the fixtures' object holds only Swift's
  force-load stub, and with it the fixtures' symbols and type names. A full Release build of the app cannot be made
  to check further, since the Swift compiler crashes on StatusKit in Release. StatusKit is unchanged since this run's
  base, so M3 does not own that crash. No M3 path
  lets a user declare a driver. A declaration comes from a saved layout, an undo, or the window's own call, which M4's
  layout requests will use.
- Driver tests run a perl fixture with one mode per behavior. `ExecPaneUITests` passed its two tests in the real app.
  One restores an exec pane, answers the values sheet, approves once in the panel, and sees commands, an event, and
  stderr. The other presses Cmd-D while a stalled driver is flooded with events. The new frame reader fuzzer is in
  `make fuzz`. `make test-app` passes `-collect-test-diagnostics never`, so a failure attaches no screen recording.
  The best guesses are in the 2026-11-11 Decision Log entries.
- The UI tests failed 4 times in 76 iterations across the fix round. Three failures were a synthesized click with no
  effect, on Run, on the Pending Requests menu item, or on Allow Once. Each of those was followed by a 5.4-second wait
  for the app to go idle, where 576 passing clicks took at most 0.74 seconds. In the fourth, XCTest found another app's
  windows above uniterm's. No cause in uniterm or the test was found. The last 40 iterations passed. The test now
  records the app's state and the time of every interaction, and a failure reports that trail and the history rows it
  read.

### M4: Layout requests

Superseded in part by UTERM-036; see Decision Log.

**Status:** DONE

- Layout requests build on the group node kind from M2 and the layout envelope, which M3 left at version 3. Amended
  2026-11-11; see Decision Log.
- A program can request a layout for its own subtree
- A request for panes outside its subtree is refused
- Publication rechecks grants after asynchronous preparation; revocation or source close leaves no partial layout
- Relaunch preserves group geometry and inert declarations while restoring no owner, grants, or automatic exec launch
- Undo assigns a new unowned pane identity even inside an existing group
- Malformed, duplicate, or cross-window saved membership cannot expand a grant
- Old layouts migrate without grants; older readers keep the newer envelope aside; unknown applet bytes round-trip
- The presentation example works end to end through real control transport with hosted slide, notes, and chart
  fixtures in separate panes; the test does not require implementing the production applet proposals

**As built:**

- The tree gained one layout edit. It finds the innermost group the owner owns with the anchor as its source. With
  one, the layout replaces that group's content and keeps its members. Without one, it wraps the anchor and the new
  panes in a new group, nested inside any group the anchor is a member of. Each rule is checked before any ID is
  used, and a layout that does not fit changes nothing. The tree also gained adoption of a group that has no owner.
- A request is checked, then staged, then published. The window reads the layout and checks the anchor and every
  placed pane. It then runs the layout against a copy of the tree, and only then builds each new applet, unstarted.
  Next it checks each new pane's directory off the main actor. Then it checks the caller's authority again, and the
  tree runs the layout once more against the tree as it is then. Only then do the panes appear and the applets start,
  each with its control set first. Any refusal closes every staged applet. A grant revoked, a source disconnected, a
  source closed, a driver's run ended, or a driver's pane closed during the directory check publishes nothing. Focus
  stays where it was.
- A controller has at most one layout in preparation. A second one is refused before anything is built, with a new
  `busy` failure kind on the script wire and the exec wire's existing `busy` error code. Both say the call may be
  sent again once the first is answered.
- A layout's exec declaration attaches inert. The pane shows Run, and no launch waits for approval until the user
  chooses it. So no program starts before the tree commits.
- `uniterm/request-layout` writes the layout through the shim's JSON writer, at most 32 KiB, and raises a struct of
  `:kind` and `:message` on failure. ScriptWire is at version 7. The writer now names what it writes in each error.
- The exec protocol is at version 2. A driver's run gets its own owner, and its groups lose that owner when the run
  ends, the pane closes, or the user revokes it. Revoke Controller on any member reaches a driver owner too. A revoke
  holds for the rest of the run: the run lays out and commands nothing beyond its own pane again, and a layout in
  preparation at the revoke publishes nothing. The run keeps its own pane, and a new run starts clear. The perl
  driver fixture speaks version 2. Its `layout` mode sends a layout, then commands for the panes in the reply.
- A layout may open an applet type the window declares beyond the built-in kinds. That is how the hosted fixtures
  open. The app's factory makes them only in a debug build with `UNITERM_TEST_APPLETS`, and refuses the type
  otherwise. `open-pane` still takes only the built-in kinds.
- The badge of a member of a group with no owner offers Give Group to each connection that acts for a pane of the
  window and is not revoked. The group keeps the members it holds, and each keeps its mode, so the user enables the
  ones the controller should drive. A connection of another window is never offered.
- Restore needed no codec change. M2's and M3's tests already prove that groups, geometry, member IDs, saved modes, and
  exec declarations save as inert intent. They also prove a restore comes back disconnected with no owner and runs
  nothing, that a version 1 or 2 file upgrades, and that a damaged member list only shrinks a group. UTERM-001's tests
  prove that a newer file is kept aside and that unknown applet bytes round-trip. M4 added the window-level checks: undo
  inside a group gives a new pane that is no member, a file with repeated, outside, and other-window members gives a
  controller only the member the group holds, and the badge is the only way a restored group gains an owner.
- A package test runs a real Janet script in the real helper, over the real listener, against a real window. It lays
  out the slides, notes, and chart fixtures beside its own pane and drives each one. It then saves and restores the
  window. A UI test runs the same script from the app's terminal with the bundled command. Its capture holds the whole
  window. By then the shell has cleared its screen and shows only a synthetic prompt, and the test checks that before
  it keeps the capture. The best guesses are in the 2026-11-11 Decision Log
  entries about layout requests.
- Every pane's applet view now joins the window at its pane's size. A new pane takes its frame before it joins the
  pane area, and the pane area starts at the window's content size, so a new window's first pane and a restored
  window's panes have room too. An applet view that entered at zero width broke its own inset constraints.

### M5: Verified controller artifacts and run binding

**Status:** DONE

- Binary and Janet controller fixtures verify descriptor, packaged entry, and dependencies before persistent admission
- Ordinary source replacement before, during, or after snapshot creation cannot substitute unverified packaged code
- Duplicate descriptor fields, path aliases, escapes, symlinks, missing files, and unlisted code fail closed
- The real Janet loader rejects ambient dependencies, delayed external imports, and startup injection paths. The real
  native load check rejects load commands and search paths that reach outside the package and the system. Amended
  2026-11-11; see Decision Log.
- Loader variables cannot execute substitute code before helper admission or silently override the declared boundary
- The bundle helper evaluates no user code before verified admission and sandbox selection
- The CLI retains its own stdin/stdout/stderr, signals, directory, and exit status without an app-side I/O relay
- An arbitrary interpreter claiming an approved script digest receives no persistent script authority
- PID reuse and successful exec invalidate live bindings; queued calls from the old generation have no authority
- Optional local signing works without an Apple developer certificate; bad signatures and changed keys do not reuse
  trust
- App, signer, and loader share deterministic descriptor interpretation and signature verification fixtures
- Original-path updates cannot alter the retained snapshot used by an admitted run

**As built:**

- A new module reads the descriptor, the signature, and a native entry's load commands, and makes and loads snapshots.
  The app, the signer, and the helper's loader all read through it. Its strict JSON reader replaces Foundation's,
  which keeps the last of two equal keys. The shared fixtures are one signed Janet package and 18 bad descriptors.
  Their expected digests came from `shasum`, and their signature and key fingerprint from a separate CryptoKit
  program. The app's, the signer's, and the loader's tests each hold them. Both readers and the load check are in
  `make fuzz`.
- The app copies a package from bytes it reads once, through descriptors that never follow a link, and checks each
  digest on the copied bytes. It then walks the finished copy and reads it again before it locks the copy read-only.
  A package holding a link, a FIFO, a missing file, or a file the descriptor does not list is refused, and so is a file
  that changes during the copy. The test that changes the source mid-copy uses a hook between files, not a race. The
  first draft listed a folder through a duplicated descriptor. That shared the folder's read offset, so the second
  listing of the copy saw nothing and its folders stayed writable. The read-only test caught it.
- Each instance keeps its snapshots in a folder of its own under the user's caches, named for its process, and a
  launch removes only the folders of instances that have ended. A Janet run's snapshot goes when its connection
  closes, also after a revoke. A native run's goes when its process exits or execs again. Review of the first draft
  found that a revoke stranded a Janet run's snapshot, and that a launch removed every instance's runs. Each test
  failed with its fix reverted.
- `uniterm run` takes a package folder. The command sends `controller-begin` and reads nothing of the package before
  the app answers. It then loads the snapshot and checks its descriptor against the version the app verified. Janet's
  module paths and loaders are replaced with one resolver and one loader that serve the package's files from memory.
  The test grants fs-read, so the loader and not the sandbox refuses imports from the working folder, JANET_PATH, an
  absolute path, a native module, an image, and an import a function makes after startup. An ordinary script in the
  same folder does load the ambient module. SIGINT stops a package in its entry and inside a module load. The loader
  lives in Janet's own module tables, which a script can change. A package granted fs-read can therefore put a file
  loader back and import from disk. That is the accepted case of a trusted program interpreting external input.
- `uniterm controller run` asks the app to admit a native package, then execs the snapshot's entry in its own process.
  The entry keeps the command's terminal, folder, and arguments, and its exit status and signals are the process's
  own. The entry's connection gets the run only when it comes from that process with the same start time, after an
  exec, running code whose hash matches the snapshot's entry. That check asks for the running code's dynamic signing
  information only, and runs on the main actor. Whether Security reads the file to answer it was not measured. A
  second exec ends the run and its snapshot while the process still runs. The native fixture is a SwiftPM executable.
  A copy whose load commands name a library outside the system is refused before it runs. The load check reads load
  commands only, so the check bullet on native loaders is narrowed to them. Review found that an `@rpath` library
  whose first candidate was a system path left its packaged candidate unchecked. Every packaged candidate is now
  checked, and the test failed before the fix.
- The app knows its bundle's command by its code directory hash, and the command is signed so that dyld variables
  cannot reach it. The 2026-11-11 Decision Log entries on the hardened command say why and what it costs.
  `check-sandbox-off.sh` checks the built command's runtime flag. It also checks that the command's entitlements
  file holds only the entitlement for unsigned executable memory, and that the built command carries it and no
  sandbox, file, network, exception, or other `cs.` entitlement. `make test-helper-sandbox` checks that an injected
  library does not load into it, and that a `--allow ffi-jit` sample runs JIT code in it. The sample was killed by
  the kernel before the entitlement was added. Package tests stand in a copy of the SwiftPM helper, signed the same
  way, for the bundle's command. The unsigned helper then plays another interpreter, which gets no controller run.
- The first UI run refused a package run over `__XPC_DYLD_FRAMEWORK_PATH`, which Xcode sets for an app under test and
  its terminals inherit. dyld never reads `__XPC_DYLD_` variables, so they no longer count as loader variables. The
  test of the variable list failed before the fix.
- Every connection is checked against the process ID version in its peer's audit token, read from the socket at each
  call. A process watch ends a connection's authority as soon as its peer execs. A call read before the exec and
  dispatched after it is refused. The exec test failed with the check removed. A forked child that writes on the
  inherited socket while the process that connected still runs is refused too, since the audit token names the
  process that last wrote. A first draft also closed a
  connection whose peer exited, which broke M1's test of a socket left to a forked child. A peer that exits now fails
  at its next call, as in M1.
- Signing is `uniterm controller keygen` and `uniterm controller sign`, with a key file. A bad signature refuses the
  run, and a package signed with a new key has a new identity.
- Persistent admission has no remembered trust yet. A run's authority over panes still comes from its ancestry or an
  explicit grant from M1, and M6 adds the startup review and remembered policies. The first check bullet's "before
  persistent admission" and the tenth's "changed keys do not reuse trust" are exercised as identity changes: a
  refused run, and a new key fingerprint for a new key. M6's trust store will hold the trust they speak of.
- A UI test runs a package from the app's terminal with the bundled command, then runs it again after an edit and
  sees it refused. It compiles and is run by the coordinator. The best guesses are in the 2026-11-11 Decision Log
  entries about controller packages, the hardened command, and the generation check.

### M6: Consent, remembered trust, and permission management

**Status:** DONE

- Startup shows requested powers once, with Allow once, Session, Trust this version, and eligible Trust this identity
- Unchanged or narrower scoped requests reuse approval; new powers, wider scopes, or unsupported meanings do not
- Runtime argument/environment values vary within approved launch scopes without repeated prompts or saved secrets
- Typed controller clipboard reads and writes enforce separate grants at the actual access boundary
- Shared-terminal OSC 52 offers once/session permission without claiming persistent controller identity
- Coalesced requests never widen Allow once, and repeated or denied requests cannot create modal floods
- Controllers & Permissions shows version/key selectors, approved scopes, active runs, and usable revocation
- Revocation, disconnect, and session replacement invalidate queued clipboard access and staged host launches
- The separate policy file is private and atomic; corrupt or newer policy state grants nothing and stays recoverable
- Signing tooling creates optional local keys in Keychain; losing a key never silently substitutes another identity
- Old/new admission and typed clipboard versions refuse unsupported contracts in both directions before effects
- Remembered trust neither overrides disconnected existing panes nor adopts restored group members or activates Run

**As built:**

- A controller run that asks for any power waits for a startup review in the Pending Requests panel. Review opens a
  sheet that lists every requested power, what is new beside an earlier approval, the version, and the key. Deny is the
  default button. Trust This Identity shows only for a signed package, and neither trust choice shows when the policy
  file cannot take one. The sheet's help describes only the choices it shows. The command says once that it waits. It
  then waits with no timeout. A run that asks for no power starts at once. Allow once starts the run with its
  capabilities, and each later use of another power asks again. Runs of one version that ask for the same powers share
  one review, and Allow once or Allow for this session starts the oldest alone. See the 2026-11-12 Decision Log entries
  on Allow once and on runs that ask for nothing.
- Remembered policies live in a new module with no AppKit, beside a shared atomic writer that the layout store now
  uses too. Every read and change of the policy file takes a lock on its folder, so two running instances keep each
  other's changes. The store refuses a link in place of its folder and anything but a regular file in place of the
  policy file. The policy reader is strict JSON and is in `make fuzz`. Which policy covers a run, and how a trust
  choice changes an earlier policy, are in the 2026-11-12 Decision Log entries on covering policies.
- Typed clipboard reads and writes reach the general pasteboard through one access point, which reads off the main
  actor; see the 2026-11-12 Decision Log entry on clipboard reads. Questions wait in the panel
  within the bounds the coalescing bullet names. A revoke, a closed connection, a lost binding, an ended session, an
  ended driver run, and a closed pane withdraw their waiting requests: the program is refused, and no denial is
  recorded. A Janet read gets its text by the route the 2026-11-12 entry on Janet clipboard replies describes. A
  driver's clipboard text is bounded so that it always fits one exec frame; see the 2026-11-12 entry on the exec
  clipboard bound. Denials are kept until Ask Again however many there are; see the 2026-11-12 entry on dropping
  the denial bound.
- A controlled terminal's OSC 52 question, and a controlled REPL's, waits in the panel like any other, labelled as
  covering the programs in the tab or the REPL, with no controller named.
- Controllers & Permissions is in the Window menu and the palette. It lists remembered approvals by selector, with the
  full fingerprint or version and the scopes, and the live runs with their approval. Revoke on an approval removes it
  from the file, then ends the runs it admitted. Revoke on a run ends that run alone, as the badge's Revoke does. The
  Pending Requests panel and Controllers & Permissions keep the row the user chose selected while other rows come
  and go, and select nothing once it is gone.
- Signing keys live in the login Keychain, and the signing commands' tests use a key store in memory. One test
  reaches the real Keychain under a service name of its own. Whether a rebuilt ad hoc command reads an item an earlier
  build made without a system prompt was not probed.
- Descriptor format 2 follows the per-permission version that UTERM-019's review settled; see the 2026-11-12 Decision
  Log entry. The shared descriptor fixtures cover each format 2 refusal, and one good format 2 descriptor joins the
  fuzz corpus.
- Debug builds take the policy folder from the environment, so the UI tests never touch the developer's policy file.
  A UI test drives the review sheet and Controllers & Permissions.

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-10-31: This proposal defines the group node kind, at the user's request during the UTERM-001 review.
- 2026-11-01: Added context from UTERM-001's implementation to "What anchors trust" and "Saved layouts", and
  added "Clipboard access from controlled panes".
- 2026-11-02: Review start: 4 milestones, 5 settled decisions, 3 risks, no Live after lines or row gates,
  no explicit out-of-scope statements; at commit
  "Merge pull request #13 from space-armada/agent/cg-and-worktree-ignore".
  The user requested a full autonomous review and one commit at the end.
- 2026-11-02: Exec is an independent driver setting, combinable with remote-controlled or disconnected access.
  Converged in 1 pass (autonomous). Revised the settled three-level definition and M2's blanket rejection wording.
  Routed shared dispatch and host-shortcut checks to M2 and M3.
- 2026-11-02: Caller identity uses authenticated peer identity and live ancestry to a recorded session root, with
  explicit connection grants when unbound. Requires a narrow libghostty identity patch. Converged in 1 pass
  (autonomous). Routed backend identity and connection-lifecycle findings to M1.
- 2026-11-02: Fired UTERM-003's REPL-capability hook. User-selected grants require a fresh helper; host-side program
  launches need separate local approval. Converged in 1 pass (autonomous, addition). Routed approval binding and
  generation revocation to M1-M3. Added the mode-default question to finish the control boundary.
- 2026-11-02: Controlled clipboard reads and writes require local confirmation (autonomous, addition).
  Adds per-session terminal policy and restores OSC 52 write confirmation. Converged in 1 pass; M2 checks both paths.
- 2026-11-02: Exec uses versioned JSON lines with applet schemas, bounded pipes, and source-labelled stderr.
  Converged in 1 pass (autonomous). Routed skew, overload, and asynchronous cleanup checks to M3.
- 2026-11-02: Trust anchors to explicit membership in a nonmerging owner group. Converged in 1 pass (autonomous).
  Amended the settled tree-shape trust rule. Routed publication revalidation to M4.
- 2026-11-02: New user panes default disconnected; local chrome enables control and separately revokes a controller.
  Authorized new group panes may explicitly start remote-controlled. Converged in 1 pass (autonomous).
  Routed accessible enablement and policy-transition checks to M2. Added exec launch context for explicit state flow.
- 2026-11-02: Exec declares argv, directory, and environment explicitly, with home and a documented OS base as defaults.
  No app or neighbor inheritance; environment values are not saved. Converged in 1 pass (autonomous). Routed restore
  and launch-context checks to M3. Raised for the user per CLAUDE.md "Applet Attributes".
- 2026-11-02: Nearest means authorized tree-distance selection with deterministic ties; no match fails without
  creation. Converged in 1 pass (autonomous). Routed tree-distance behavior to M2.
- 2026-11-02: Save program layout intent but no live authority, capabilities, or environment values. Relaunch and undo
  require explicit regrant, and exec requires Run. Bump the envelope schema and retain ADR-06's downgrade behavior.
  Converged in 1 pass (autonomous). Routed restore and malformed-membership checks to M4.
- 2026-11-02: Risk review recorded same-user relay exposure, terminal backend patch maintenance, in-flight applet and
  scripting contracts, inert-restore/downgrade exposure, and approved programs' OS privileges (autonomous). Existing
  mitigations and explicit residual acceptances cover each; no high-likelihood/high-impact risk remains unmitigated.
- 2026-11-02: Clarified M4's end-to-end presentation check to use hosted slide, notes, and chart fixtures through the
  real transport, leaving production applets in their own proposals. This interpretation is for the user's review gate.
- 2026-11-02: Coherence review found no conflicting or weak decisions. Routed multi-tab clipboard policy to M2.
  Marked separate host-launch approval as an addition because it introduces a permission boundary for host execution.

- 2026-11-02: Whole-proposal review converged in 2 passes. No design questions or contested rulings remain. Across
  the review, 17 findings were routed to checks in M1-M4. No milestone, Live after line, or queue gate was added.
  Review size: 4 to 4 milestones, 5 to 15 settled decisions, and 3 to 8 risks. Clipboard policy, host-launch approval,
  exec state flow, and the M4 fixture interpretation remain for the user's gate.
- 2026-11-02: Review gate, partial: the user kept explicit exec launch context and defaults, and kept M4's hosted
  fixture end-to-end check. Clipboard confirmation and separate host-launch approval remain under discussion.
- 2026-11-02: The user found the permission boundaries sane but raised habituation from repeated dialogs. Reopened
  consent granularity for discussion; no replacement consent policy is chosen yet.
- 2026-11-02: The user confirmed that approval once at startup is the goal and asked how grants identify their
  requester. Requester identity and consent scope remain under discussion.
- 2026-11-02: Requester replacement discussion identified that process lifetime, executable lifetime, interpreter
  code identity, and terminal-session scope are distinct. macOS exposes exec notifications, but notification alone
  does not prove race-free per-request identity. No stronger requester-identity guarantee is settled yet.
- 2026-11-02: The user clarified that the goal is durable executable trust across sessions when requested grants
  remain the same. Earlier run-only recommendations misunderstood the requirement. Reopened persisted approval
  policy, executable recognition across updates, and permission comparison; live connections still need fresh binding.
- 2026-11-02: The user chose three consent durations: once, this session, and persistent controller trust. Required
  that users need not buy an Apple developer certificate. Asked how binary and script controller identities relate
  to signing; that mechanism remains open.
- 2026-11-02: The user approved the version-trust versus identity-trust distinction and requested its structure.
  Reviewed a common binary/script descriptor, optional local signing, durable permission policies, and fresh run
  binding. The critic ranked it first, with dependency coverage and execution binding still open. No detailed
  signing or packaging mechanism is settled. These additions follow the user's persistent-trust requirement.

- 2026-11-02: The user accepted the controller framework, four approval choices, packaged-code/dependency coverage,
  verified run binding, and Controllers & Permissions (addition). Persistent trust, optional local signing, and
  management UI are now approved scope. Detailed artifact loading and integration of permission scopes remain open.

- 2026-11-02: The user chose scoped powers over exact launch-input matching. Converged in 1 critic pass. Runtime
  arguments and values may vary within approved entry, directory, environment-key, and target scopes. Added typed
  controller clipboard requests (addition); shared-terminal OSC 52 retains once/session scope. Updated the previous
  per-operation consent, reconnect, launch, and restore wording to separate saved policy from live authority.

- 2026-11-02: The user chose verified snapshots while preserving the CLI-owned Janet VM. Converged in 1 critic pass.
  Added M5 for artifact verification, fixed loading, optional local signing, and actual run binding. The accepted
  threat model does not claim atomic Unix-stream sender attestation or same-user isolation.
- 2026-11-02: Added M6 for the user-approved consent framework, scoped powers, durable approvals, typed clipboard
  access, and Controllers & Permissions. M5-M6 implement approved additions, with no scheduling or deployment gate.
  Risk review added signed-update continuity, load divergence, policy semantics/skew, and prompt/attribution exposure.

- 2026-11-02: Final coherence review of the revised framework is SOUND in 1 full pass, with no new findings, dissent,
  or open questions. The user-resolved mechanism reviews each converged in 1 pass. Across the full review, 22 findings
  were routed to M1-M6 checks. Size against Review start: 4 to 6 milestones, 5 to 18 settled decisions, 3 to 12 risks.
  M5-M6 implement the user-approved durable-trust scope; no Live after line, queue row, or deployment gate was added.

- 2026-11-02: Review gate: the user kept the completed design with nothing reopened and accepted the proposal.
  Acceptance does not schedule M1-M6; the queue is unchanged.
- 2026-11-02: ADR candidate (cuts across the system): control authority requires an authenticated requester and
  explicit scope; reusable trust is verified afresh for each run and cannot silently widen permissions.
  Written as ADR-09 on 2026-11-02.
  This includes the user-approved durable-controller-trust addition. The invariant is settled and independent of
  package syntax, signing format, or applet-specific command schemas.

- 2026-11-02: The user selected ADR-09 and authorized including the required proposal-index update in the single
  final commit. ADR-09 records the authenticated-requester and explicit-scope invariant, including durable controller
  trust, after consulting the Architecture, Decision, and Record requirements.

- 2026-11-02: Final ADR review passed Architecture, Decision, and Record and found no unsupported clauses, format,
  or linking defects. It surfaced the permission and durable-trust additions becoming architectural rules; the user
  had explicitly approved those additions and selected the disclosed ADR candidate. Review complete: proposal and
  ADR-09 accepted, M1-M6 unscheduled, and the required index update included in the one final commit.


- 2026-11-03: Amended at the user's request during the UTERM-008 review. "Exec wire format" now names the applet
  contract's command and event hook and a remote host call, `uniterm/send-command`, that carries one applet command.
  The text before said only that exec and remote commands share dispatch and that remote host calls use the same
  validation; neither part was named or built by a milestone. Supported combinations are declared by every applet,
  apart from commands, and remote commands name the applet type and schema version they target. Added checks to M3,
  which builds the hook. The map's program-pin
  milestone depends on both. A re-check converged on the second pass. Moved the shared-dispatch check from M2 to M3,
  since exec drivers and the hook are built there. (addition: the command and event hook, a combination declaration on
  every applet type, and a host function in UTERM-003's module)
- 2026-11-03: ADR candidate (hard to reverse): every applet command, exec or remote, names its applet schema version,
  and an unsupported version is refused before any effect. Declined: the user judged it does not rise to an ADR.
- 2026-11-03: Scheduled as UTERM-004 M1-M6 in queue.md.
- 2026-11-06: Amended driver stderr and the pending-permission indicator (work-queue best guess). "Control modes" said
  stderr goes to the status bar, and its check said stderr appears there, with no level, no coalescing, and no word on
  failures. The permission indicator was "host-owned" with no named place. UTERM-017 settles that raw stderr is
  info-level text, bounded and coalesced before admission, and that host-observed failures are typed warnings or errors.
  It also gives the indicator a slot, the pending-permissions window state. The slot is built there, and this proposal
  fills it when its permission panel exists. The driver wire format does not change. UTERM-017 M2 later settled that
  stderr goes to the history only, with no turn on the bar, so a flood cannot bury a real notice. The text and check
  above were amended to match.
- 2026-11-07: Amended "Clipboard access from controlled panes" at the user's request, after the Ghostty 1.4.0 bump.
  The context said writes go through because the config sets `clipboard-write` to `allow`, and that a write prompt
  means restoring a removed write case. The surface bullet said both the confirm and write callbacks enforce policy and
  to restore the write request case. The bump sets `clipboard-write` to `ask` so that Kitty writes reach the confirm
  callback, which denies them. OSC 52 writes now arrive at the write callback with a confirm flag and are allowed
  there, so M2's write gate belongs in that callback. The earlier "Amended 2026-11-02" marker pointed at "Permission
  scopes and approval flow", which still holds the 2026-11-02 change. The decision itself does not change.
- 2026-11-10: Amended "How uniterm knows which pane a program runs in" during M1 implementation (work-queue best
  guess). The proposal said libghostty's public API exposes no PID. It does expose `ghostty_surface_foreground_pid`,
  but that is the pty's foreground process group, not the spawned child, so the backend patch is still needed. The
  patch adds a `child_started` action that reports the spawned child. The spawned child is setuid-root `/usr/bin/login`.
  `proc_pidinfo` refuses a root process for a non-root caller, so ProcessInspection uses sysctl(KERN_PROC_PID) instead
  to read kinfo_proc for start time and parent relationships, avoiding EPERM. The peer's uid comes from
  LOCAL_PEERCRED and its PID from LOCAL_PEERPID. The bullet keeps its generation, its typed identity event, and the
  rule that no other module reaches through the terminal boundary.
- 2026-11-10: Amended the grant bullet of "How uniterm knows which pane a program runs in" during M1 implementation
  (work-queue best guess). It said the user grants "a named source pane" and that a grant ends on revocation, and was
  silent on tabs and on asking again. A terminal pane with several tabs runs several sessions, and the script host
  knows panes, not tabs. A grant now binds to the newest session still running in the pane. A denied or revoked
  connection is not asked about again, so a program that keeps retrying cannot keep the panel full. It must reconnect
  to ask again. If the user wants a grant to name a tab, the grant sheet would list tabs and the host would track
  roots by tab. The Amended marker moved here from the backend-patch bullet, whose 2026-11-10 entry is above.

- 2026-11-10: Moved the group node kind into M2 (work-queue best guess). The proposal had M4 build groups with layout
  requests, and "Group node kind" said only a layout request makes one. M2's checks need owned members, and a live group
  must save, so M2 builds the group, open-pane's owned members, and layout envelope version 2. M4 keeps layout requests
  and the restore checks. A user split of a member puts the new pane inside the group's area, not among its members,
  and a group is removed once it has no member. The source pane is not a member. "What anchors trust" said "An empty
  group is removed and its ID retires." It now says a group left with no member is removed, and that the source is
  placement metadata. It said "User splits create panes outside the owned group boundary." It now adds that a user
  split of a member puts the new pane beside it, inside the group's area but not among its members. If the user wants
  user splits placed outside the group's area instead, a split of a member would split beside the whole group.
- 2026-11-10: Put UTERM-003's host API behind pane authority (work-queue best guess). The proposal settles the scope
  rules but not each call's answer. `list-windows` returns the caller's own window, with its pane and that pane's mode,
  and adds the title only once the pane is enabled. `list-panes`, reads, `send`, `open-tab`, and `open-pane` reach the
  caller's own remote-controlled pane and remote-controlled members of groups it owns. A target out of scope answers as
  one that is not open. A caller whose pane is disconnected and owns no group gets an error naming Enable Remote
  Control. One that owns a group keeps its members but cannot act on its own pane. `post-status` stays open to bound
  callers. Open-pane takes `:control :disconnected`, the default, or `:remote-controlled`. If the user wants another
  default, scripts that send to a pane they open would change.
- 2026-11-10: Named nearest targets `{:nearest kind}` in place of a pane reference (work-queue best guess). "Nearest"
  pane did not say how a script names one, or whether the caller's own pane counts. It counts. The form changes the
  wire, so ScriptWire went from version 4 to 5 here, and M3's bump becomes 6. The hello is one 16-bit version in every
  version, and each side refuses any version but its own before a call runs. An old `uniterm` command with a new app,
  and a new command with an old app, are both refused at the hello. No deploy order is needed. If the user wants
  a separate call, the wire would carry a new call code instead.
- 2026-11-10: Settled controlled-terminal clipboard details (work-queue best guess). The prompt offers Deny, Allow Once,
  and a button that allows reads, or writes, in the tab. Each kind's session permission ends with any policy change,
  including a new generation from a revoke. An unsafe paste keeps its own question. If the user wants a session
  permission to survive a revoke, the generation check would narrow to the mode. A session holds at most one waiting
  prompt per kind: a later read or write of that kind is denied at once, with no prompt, and its text dropped. That
  bounds the prompts "Permission scopes and approval flow" forbids flooding until M6's coalesced panel can replace it.

- 2026-11-11: Bumped the layout envelope to version 3 for the exec declaration (work-queue best guess). "Saved layouts"
  said the group and the mode and driver metadata bump the envelope, and M2's version 2 carried only the access mode
  and driver kind. The declaration adds fields a version 2 reader drops on its next save, so ADR-06 bumps the
  version. The step from version 2 keeps the windows list byte for byte. The bullet now names both bumps.
- 2026-11-11: Gave M3 a session-only launch grant short of packaged entries (work-queue best guess). "Permission scopes
  and approval flow" names packaged entry IDs, owned-group targets, and a directory scope, and M5 builds packaged
  entries. Until then an entry is the absolute executable, the directory scope is the one directory, and the target is
  the one pane. The grant lasts for this launch only. The bullet now says so, and the section's Amended marker moved to
  it from the pending-indicator bullet, whose 2026-11-06 change is logged above. If the user wants a directory scope
  that covers subfolders, or a grant for an owned group, the grant would take a folder prefix or a group.
- 2026-11-11: Settled M3's exec details (work-queue best guess). The applet owns the driver's child through its event
  outlet, so the applet's close shuts it down, as ADR-05 asks. The window owns the authority and ends it at once. An
  event emitted before both hellos goes nowhere. A driver that writes faster than the pane handles past 4 MiB fails,
  as the bounds say, and is not slowed down. A driver that never sends its hello has no timeout. It runs no command
  and gets no event. A launch's values come from a sheet with secure fields and are shown in the Pending Requests
  panel, since Allow once shows what it binds. If the user wants a hello timeout, the channel would take an injected
  clock.
- 2026-11-11: Gave remote command failures their own Janet form (work-queue best guess). The proposal says a script
  gets the error as a Janet value. Every other host call raises a string. `uniterm/send-command` raises a struct of
  `:kind` and `:message`, where the kind is one of the wire's failure kinds, with a new `unsupported` kind for a type
  or schema version the pane does not take. Replies carry numbers that are negative or not whole as doubles. If the
  user wants every call to raise structs, the other host functions would change for existing scripts.
- 2026-11-11: Compiled the hosted fixtures out of release builds entirely (work-queue best guess). The plan said the
  debug registration compiles out of Release. The app links the fixtures' target in every configuration, since Xcode
  links a package product for all of them. The target's sources now sit under DEBUG too, so release code holds none of
  them. If the user wants the target unlinked from Release instead, the Xcode project would need a per-configuration
  link, which it does not support cleanly.
- 2026-11-11: Ended a driver's whole process group when the driver ends, however it ends (work-queue best guess).
  Review found that a program the driver started, which ignores SIGTERM and holds stdout open, outlived a close. The
  driver now stays a zombie until its group has had SIGKILL. That also ends such a program when the driver exits by
  itself. A program that should outlive its driver must leave the group. At quit, the shared wait for SIGTERM is half
  a second before SIGKILL, a bound ADR-08 allows. If the user wants a driver's background programs to survive its own
  exit, the kill would apply only on close and at quit.
- 2026-11-11: Reported a reply that cannot reach a script as `reply-lost` (work-queue best guess). A command that ran
  but whose reply could not be encoded reached the script as an ordinary failure, which reads as no effect. The new
  failure kind says the command ran. If the user wants such replies cut down to fit, the window side would shorten
  them in place of failing.
- 2026-11-11: Added no user path to declare an exec driver in M3 (work-queue best guess). The plan named none, and no
  shipped applet supports a driver. A declaration comes from a saved layout, an undo, or the window's own call. M4's
  layout requests will call it. If the user wants a declaration sheet now, the pane chrome would gain one.
- 2026-11-11: Settled the form of a layout request (work-queue best guess). "Layout requests" said only that a trusted
  program may request a layout for its own subtree, and named no call, shape, or wire. It now names
  `uniterm/request-layout` and a driver's `layout` message, one JSON layout of splits, open panes, and new panes, and
  the bounds of 16 panes and 6 levels of splits. The request is anchored at a pane the program may address, and the
  reply names the pane at each leaf. A first layout from a member of a group makes a nested group, as "What anchors
  trust" asks. Focus stays where it was. If the user wants another shape, such as a list of panes with placements, only
  the reader in the window and the shim's docstring would change.
- 2026-11-11: Refused a later layout while its group holds a pane it does not own (work-queue best guess). "What
  anchors trust" said: "Later requests rearrange only still-owned members and create new ones. They cannot import
  unrelated panes, replace existing applets, or silently discard members." It did not say what happens to a pane the
  user split off inside the group, or to another controller's nested group. Rearranging the group would either take
  such a pane in or drop it, so the request is refused, and the bullet now says so. The section's Amended marker moved
  here from the 2026-11-10 entry, which is above. If the user wants such a pane to move with the member beside it, the
  tree would place each foreign block with its member.
- 2026-11-11: Moved the script wire to version 7 for `uniterm/request-layout` (work-queue best guess). The call takes a
  new call code and carries the layout as JSON text, at most 32 KiB. The hello is one 16-bit version in every version,
  and each side refuses any version but its own before a call runs. An old `uniterm` command with a new app, and a new
  command with an old app, are both refused at the hello. No deploy order is needed. A failure raises a struct of
  `:kind` and `:message`, as `uniterm/send-command` does, since a layout's refusals have kinds a script can act on.
- 2026-11-11: Let an exec driver lay out its subtree and command the members it owns, in exec protocol version 2
  (work-queue best guess, addition: drivers commanding panes beyond their own). The plan named an exec command for
  layouts. A layout a driver cannot command would be inert. "Trust follows the pane tree" lets a program address the
  panes of groups it owns. A command to another pane names the pane, the applet type, and the schema version. Both need
  the driver's own pane to be remote-controlled, since the user's enable is what lets a program in a pane act beyond it.
  Each run owns its own groups, and loses them when it ends, its pane closes, or the user revokes it. Revoking leaves
  the attached channel, as "What anchors trust" says. Each side refuses any other exec version at the hello, so neither
  skew direction runs a command. "Exec wire format" now says so, and its Amended marker moved here from the 2026-11-03
  entry, which is above. If the user wants drivers kept to their own applet, the `layout` message would stay and the
  pane field would go.
- 2026-11-11: Attached a layout's exec declarations inert (work-queue best guess). "What anchors trust" says approved
  programs start only after the tree commits, and M3 settled that no script reaches Run. A layout's driver therefore
  shows Run in its pane, and no launch waits in Pending Requests until the user chooses Run. If the user wants a layout
  to file its launches for approval at once, the commit would file them, still with no automatic start.
- 2026-11-11: Gave restored groups to a controller from the badge (work-queue best guess). "Saved layouts" says the user
  may grant a new live connection the exact restored member set through pane chrome. The badge of a member of a group
  with no owner lists Give Group to each connection that acts for a pane of the window and is not revoked. The group
  keeps the members it holds, and each keeps its mode, so the user enables the targets separately. A driver is not
  offered, since a new exec attachment gains no restored siblings. If the user wants a picker of members, the action
  would take a subset and the group would split.
- 2026-11-11: Opened applet types the window declares beyond the built-in kinds, in layouts only (work-queue best
  guess). The hosted fixtures have no launcher entry, so a layout names them by type and the app's factory decides. Only
  a debug build with `UNITERM_TEST_APPLETS` declares and makes them. Release builds refuse such a type. `open-pane`
  keeps the built-in kinds. If the user wants `open-pane` to take them too, it would share the layout's kind lookup.
- 2026-11-11: Amended M4's first bullet. It said layout requests build on "layout envelope version 2 from M2". M3 moved
  the envelope to version 3 for the exec declaration. M4 changes no saved data, so the envelope stays at version 3.
- 2026-11-11: Made a revoke hold for the rest of a driver's run (work-queue best guess). Review found that a revoked
  driver kept laying out from its own pane, and that a layout it had in preparation published after the revoke. "What
  anchors trust" says revocation removes the owner's authority and leaves the driver its own channel, and "How control
  is enabled" says a revoke ends the live grant. "Exec wire format" said only: "Revoking leaves the driver its own
  attached channel." A connection's revoke holds until it reconnects. A run's revoke now holds until the run ends, so
  the run acts on its own pane only, and the bullet says so. If the user wants a revoked driver to lay out again
  without a new run, the revoke would end only the groups it owned at the time.
- 2026-11-11: Allowed one layout in preparation per controller (work-queue best guess). Review found that a controller
  could send layouts faster than they finish, and each one built its applets. "Exec wire format" bounds work and queued
  bytes, and says a driver past a bound fails visibly. "Layout requests" bounded each layout's panes and depth, and
  named no bound on layouts in flight. A second layout from the same connection or run is now refused as `busy` before
  anything is built, and that section now says so. The tree check also runs before any applet is built. The script
  wire's new `busy` kind lands in ScriptWire 7 with the layout call, and the exec wire already had a `busy` code. If the
  user wants layouts queued instead, the window would hold a bounded queue per controller.
- 2026-11-11: Settled the controller descriptor and signature formats (work-queue best guess). "Verified artifact and
  run binding" named their contents and not their form. The descriptor is `controller.json` in strict JSON, format 1,
  with two permission kinds, `pane-control` and a Janet `capability`. Paths are plain ASCII with no second spelling,
  and case-only differences are refused. The signature is Ed25519 over a domain line and the exact descriptor bytes.
  The section now says so. If the user wants Unicode paths, the reader would compare paths after normalization and
  case folding instead of refusing them.
- 2026-11-11: Refused Janet native modules and images even inside the snapshot (work-queue best guess). The section
  said managed modules and native packaged libraries resolve only inside the snapshot. A Janet package now loads only
  `.janet` source, and a controller cannot declare `modules` or an `ffi` capability. Neither kind can be checked the
  way a native entry's load commands are. The bullet now says so. If the user wants packaged native modules, the loader
  would run the native load check on each before it opens one.
- 2026-11-11: Gated pane calls on a declared `pane-control` (work-queue best guess). "Controller trust and approval
  choices" says undeclared effects are refused, and named no permission for status messages. A controller run that
  does not declare pane control may post status, labelled with its name, and nothing else. If the user wants status
  gated too, format 1 would gain a `status` kind.
- 2026-11-11: Replaced "Reject conflicting explicit environment keys with an error" (work-queue best guess). The
  approved plan had the native command scrub loader variables and reject explicit ones. On the bundle's command, dyld
  removes every `DYLD_` variable before its code runs, with no message, so neither the command nor its native entry
  sees one, and none can be rejected there. A command without the hardened runtime, such as the package tests' helper,
  refuses a run while a `DYLD_` variable is set, with an error that names it. The app refuses a bundle command that
  dyld variables could reach. `__XPC_DYLD_` variables are not counted: dyld never reads them, and the first UI run
  showed Xcode setting them for an app under test, which refused every package run from its terminal. If the user wants
  an explicit error even on the hardened command, the app would have to pass the user's environment to it by another
  route.
- 2026-11-11: Signed the bundle's command with the hardened runtime and without get-task-allow (work-queue best
  guess). Its settings already enabled the hardened runtime, but Xcode drops it from an ad hoc signature and adds
  get-task-allow to a debug build. A `DYLD_INSERT_LIBRARIES` probe loaded a library into the built command under
  either, which the app's hash check cannot see. The command is now signed with `--options=runtime` and without
  get-task-allow. Its one entitlement is `com.apple.security.cs.allow-unsigned-executable-memory`. Without it,
  `uniterm run --allow ffi-jit` ends the helper with SIGKILL when its JIT code runs, since Janet maps that code with
  plain `mmap` and `mprotect`, not `MAP_JIT`. With it, a `--allow ffi-jit` sample runs in the built command, and an
  injection probe shows dyld still dropping `DYLD_` variables. `--allow modules` loads no native module in any build,
  since the vendored Janet is built with `JANET_NO_DYNAMIC_MODULES`. A probe of a native module said "dynamic modules
  not supported", so library validation never comes into play and nothing is lost there. A debug build's command can
  no longer take a debugger. UTERM-003 is named here, and in Impacts, since this run does not edit it. Amended
  2026-11-11: this entry first said the command holds no entitlement, as ADR-10 then required, and that
  `--allow ffi-jit` was lost under the bundle's command. The next entry records why that changed.
- 2026-11-11 (user decision): Removed ADR-10's sentence requiring that `check-sandbox-off.sh` confirm the unsandboxed
  command holds no entitlement. Its only stated reason was "so it cannot pass for a sandboxed one". The check meets
  that by rejecting the App Sandbox entitlement itself. The command now holds the one entitlement for unsigned
  executable memory, and `--allow ffi-jit` works under it again. The check requires that entitlements file to hold
  that key and no other. It still rejects the sandbox, file, network, and exception entitlements and every other `cs.`
  entitlement on the built command. Before this, the Impacts line for UTERM-003, the loader-variable bullet of
  "Verified artifact and run binding", and M5's As built said the command holds no entitlement and that
  `--allow ffi-jit` code no longer runs in it. Each now says what is above.
- 2026-11-11: Applied the exec generation check to every connection (work-queue best guess). "How uniterm knows which
  pane a program runs in" said a reused PID is a different instance. A process after a successful exec is one too,
  and M5's check bullet asks for it. The check reads the process ID version from the peer's audit token at each call,
  and a peer whose token cannot be read is refused at the listener, which changes M1's admission for scripts and REPLs.
  A peer that has exited fails as before. The bullet now says so, and the section's Amended marker moved to it from
  the grant bullet, whose 2026-11-10 change is logged above. If the user wants the check on controller runs only,
  ordinary bindings would keep M1's PID and start time.
- 2026-11-11: Kept snapshots per instance under the user's caches (work-queue best guess). The section said the run
  keeps a private snapshot and named no place. Each instance has its own folder, and a launch removes only ended
  instances' folders, as sent content does. If the user wants snapshots elsewhere, only the default folder changes.
- 2026-11-11: Moved the script wire to version 8 for `controller-begin` (work-queue best guess). The hello is one 16-bit
  version in every version, and each side refuses any version but its own before a call runs. An old `uniterm` command
  with a new app, and a new command with an old app, are both refused at the hello. No deploy order is needed.
- 2026-11-11: Kept signing keys in a key file until M6 (work-queue best guess). "Permission scopes and approval flow"
  says local signing keys use Keychain, and M6 builds that. M5's signer reads a file only its owner can read, behind an
  interface the Keychain store takes over. The bullet now says so, with an Amended marker.
- 2026-11-11: Narrowed M5's native loader check bullet to load commands (work-queue best guess). The bullet said real
  native and Janet loaders reject ambient dependencies, delayed external imports, and startup injection. That holds
  for the Janet loader. For a native entry, the check reads load commands and search paths, and code the entry loads
  at run time with `dlopen` can come from anywhere its privileges reach, as "Verified artifact and run binding" already
  accepts. The bullet and the section's native-library sentence now say what is enforced. If the user wants run-time
  loading bounded too, native entries would need a process sandbox, which the design does not claim.
- 2026-11-11: ADR candidate (cuts across the system): a bundle helper that runs user-chosen code outside the App
  Sandbox carries the hardened runtime and no get-task-allow, and the app trusts it only by its code hash. It would
  amend ADR-10, whose Consequences bound the command by Janet's sandbox, a memory cap, and process isolation only.
  Undecided. Found in M5.
- 2026-11-11: Fixed stale surface events in libghostty, not in uniterm (work-queue best guess). M1's capability
  restart failed about 1 run in 4 at M4 and M5. libghostty checks a queued surface event only by the surface's
  address. A restart frees the old surface and makes the new one at once, and the allocator often gives the new one
  the same address. The old session's queued exit then reached the new session. The REPL took it as the fresh
  helper's end and withdrew the token, so the helper's attach was refused. libghostty also marked the new surface
  exited, so a later key press would close it. A new patch, `002-surface-message-identity.patch`, carries each
  surface's unique ID with its queued events, and the app thread drops an event whose ID does not match the live
  surface at that address. The design text now names the patch. The other option was to drain libghostty's queue in
  uniterm right after each free, before a new surface can take the address. That rests on libghostty joining every
  thread that queues events before the free returns, and it runs other surfaces' events in the middle of a close. If
  the user would rather carry no second patch, the drain would replace it, and the regression test stays as it is.

- 2026-11-12: Built descriptor format 2 with a version on every permission (work-queue best guess, following
  UTERM-019's "Permission descriptor format" and "Who builds descriptor format 2", which the user chose for M6). The
  uncommitted first draft of M6 added the clipboard and host launch kinds in a format 2 with no version. "Verified
  artifact and run binding" said: "The descriptor is `controller.json`, format 1, read as strict JSON." and "Format 1
  knows two permission kinds [...] Any other kind is refused, so a meaning a later format adds authorizes nothing
  here." It now defines format 2 as UTERM-019 settled it, and the bullet carries the marker. One rule needed a reading:
  "the same kind listed twice is refused" would refuse a package that declares two capabilities, which format 1
  allows. A kind with a scope is listed once per scope here, a capability per name and a host launch per executable.
  If the user wants one entry per kind, a capability entry would take a list of names.
- 2026-11-12: Let Allow once approve the start alone (work-queue best guess). "Controller trust and approval choices"
  says Allow once covers "the pending operation only", and a session covers the run. At startup the pending operation
  is the start, which applies the run's capabilities. Every other power then asks per use: each pane call, each
  clipboard request, and each host launch. Allow for this session on one of those keeps that power for the run. If the
  user wants Allow once to cover a whole first run, it would match Allow for this session and one of the two could go.
- 2026-11-12: Started a run that asks for no power without a review (work-queue best guess). Such a run may only post
  status, which M5 already let it do, so a review would ask about nothing. M5's UI test runs such a package.
- 2026-11-12: Kept denials until Ask Again (work-queue best guess). "Permission scopes and approval flow" says a
  denial stops re-prompting "until a local retry". A denied startup review is keyed by the verified version, so a
  rerun of that version is refused at once. A denied power is keyed by its requester and power, and a terminal's by its
  tab and control generation. Each denial is a row in the Pending Requests panel, and Ask Again on it is the retry. At
  most 64 are kept, oldest dropped first. A requester's denials go when it ends.
- 2026-11-12: Moved controlled OSC 52 questions into the Pending Requests panel (work-queue best guess). M2 asked in a
  sheet, bounded to one per kind, "until M6's coalesced permission panel replaces this bound". Each request after a
  denial opened another sheet. The question is now a panel row like any other, and the pending-permissions slot
  shows. The ordinary disconnected terminal's read prompt and unsafe paste prompt keep their sheets.
- 2026-11-12: Let a host launch's directory cover the folders inside it (work-queue best guess). "Permission scopes
  and approval flow" named a "permitted directory scope". M3's grant held one exact directory. A narrower directory is
  then a narrower request that an approval covers. M3's pane grant from the panel keeps its exact directory. The
  host-launch bullet said: "Until M5 brings packaged entries, an entry is the declaration's absolute executable, its
  directory scope is the one directory it runs in, and its target is the one pane where the user chose Run. Such a
  grant lasts for this launch of uniterm, and M6 grows it into the startup review and remembered policies." It now
  says what M6 built, with the entry below on owning runs.
- 2026-11-12: Covered a launch only through the live run that owns the pane's group (work-queue best guess). A
  pathname cannot activate a remembered policy, so the window asks the run that owns the innermost group the pane is a
  member of. A launch in a pane no run owns, such as a restored one, still asks. A launch waiting in the panel in a pane
  whose owner's authority ends is withdrawn, which is how M6 reads "staged host launches".
- 2026-11-12: Left a newer policy file in place, and moved a corrupt one aside (work-queue best guess). The approved
  plan said a corrupt or newer file is kept aside. ADR-06 moves a newer layout aside. Moving a newer policy file would
  leave the newer build with no policies on its next launch. Later proposals add permission kinds and versions with no
  policy format change, so a file whose JSON is sound but names a pair this build lacks counts as newer too. Two
  builds that run together then never move each other's file aside. Left in place, the file survives a downgrade
  untouched, and this build grants nothing and offers no trust choice. A broken file helps no build, so it is moved
  aside, numbered, keeping 5, and a fresh file can be written. The bullet now says so.
- 2026-11-12: Named signing keys in the Keychain (work-queue best guess). M5's signer took a key file path. The
  commands now take a key name, the account of a generic-password item under the service
  `dev.uniterm.controller-signing-key` in the login Keychain. The item uses the legacy login Keychain, since an ad hoc
  command cannot hold a Keychain access group. A rebuilt command may get a system prompt to read a key an earlier
  build made, which was not probed. The bullet said: "Until M6 moves them there, the signer reads a key file that only
  its owner can read, behind an interface the Keychain store will take over." It now names the Keychain items.
- 2026-11-12: Moved the script wire to version 9 and the exec protocol to version 3 (work-queue best guess). The
  typed clipboard calls and the review notice are new on the script wire, and the clipboard messages are new on the
  exec wire. Each side refuses any other version at the hello, so no deploy order is needed. The run request bullet
  said "a `controller-begin` message on ScriptWire version 8", and the admission bullet named no version. Both now
  name version 9. UTERM-019's "Result encoding" entry also names ScriptWire 9, and lands later, so it would take
  the next version. Its owner should know.
- 2026-11-12: Let ordinary scripts use the typed clipboard with once or session answers (work-queue best guess).
  "Verified artifact and run binding" says generic peers keep explicit once/session admission without claiming
  identity. A script bound to its pane by ancestry, with no controller run, asks for each read or write, and Allow for
  This Connection keeps that power until it disconnects. Nothing about it is remembered. If the user wants clipboard
  requests from controllers alone, the calls would be refused for ordinary scripts.
- 2026-11-12: Kept several instances apart for live runs (work-queue best guess). Each running instance rereads the
  policy file at every admission, so a policy removed in one stops covering new runs in the other. A run already
  admitted in the other instance keeps its authority until it ends or is revoked there. If the user wants a removal
  to end runs everywhere, the instances would need to watch the file.
- 2026-11-12: Revoke in Controllers & Permissions removes the policy and its runs, and the badge's Revoke ends the
  live run alone (work-queue best guess). "How control is enabled" says revoking a controller ends its live grant, and
  "Permission scopes and approval flow" says revocation removes remembered policy and current authority. Two places
  keep the two meanings apart, so ending a run never forgets its trust by accident.
- 2026-11-12: ADR candidate (cuts across the system): a programmatic request never opens its own dialog. It waits in
  the host-owned panel, and its denial persists until the user retries locally. It would sit beside ADR-09.
  Undecided. Found in M6.
- 2026-11-12: Let a version policy cover a run before an identity policy, and merged a trust choice into the policy
  it widens (work-queue best guess). "Controller trust and approval choices" offers both selectors and does not say
  which one a run's approval names when both cover it. A version names the exact verified artifact, so it is the
  narrower selector, and the run is shown as a trusted version. Trust this version or Trust this identity on a
  selector that already has a policy adds the newly approved powers to it. Replacing the policy would drop powers an
  earlier review approved for a wider run. If the user wants a trust choice to replace the earlier policy, the merge
  would go.
- 2026-11-12: Gave the Janet clipboard read a raw reply (work-queue best guess). The script wire's value encoding
  holds at most 4 KiB in one string, and a clipboard read may return up to 32 KiB. The read's reply is a flag byte
  for no text, or the flag and the UTF-8 text, and nothing else on the wire changed. A longer clipboard is refused,
  not cut. The alternative was a 4 KiB cap on reads.
- 2026-11-12: Bounded the panel at 8 operations a row, 16 rows a requester, and 64 rows (work-queue best guess). The
  first round of M6 had the row and panel bounds only. A question with no scope asks on its own, so one requester
  could fill all 64 rows and leave no room for any other. The per-requester bound of 16 leaves room for at least
  four requesters. A terminal with eight tabs that all ask to read and write still fits. The coalescing bullet now
  states the bounds. It said only that requests are "bounded and coalesced".
- 2026-11-12: Kept a connection's denial past its reconnect (work-queue best guess). The entry on keeping denials
  until Ask Again said "A requester's denials go when it ends", and a script's requester was its connection. A
  denied script that disconnected and ran again was then asked again with no action from the user, which "Denial
  suppresses automatic re-prompting until a local retry" forbids. A controller run's denial is now kept under its
  verified version, as a denied startup review is. An ordinary script names nothing a new connection could not
  claim, so its denial covers every ordinary script acting for its pane, and goes when the pane closes. Its rows
  still go with its connection. A controlled REPL's questions had no scope, so a denial of one never covered the
  next. They now take the kind of request and the control generation, as a terminal tab's do. If the user wants an
  ordinary script's denial narrower, the key would need an identity the script cannot fake, which M6 does not have.
- 2026-11-12: Showed a row's oldest waiting operation (work-queue best guess). A request that joined a row kept the
  first request's text. After Allow once released that first write, the row still showed its text, and the next
  Allow once wrote text the user never saw. Each waiting operation now keeps its own text, and the row shows the
  oldest, which is the one Allow once releases.
- 2026-11-12: Sent a run to review when a policy removal overlapped its admission (work-queue best guess). Admission
  reads the policy file off the main actor, and a removal writes it off the main actor. A run whose read came before
  the removal could start under the removed policy after the revoke had ended the policy's runs. A run is now
  covered only when no removal began or ended since its admission started, and none is under way. Otherwise the
  user reviews it. A run whose review chose a trust choice while a removal ran starts for its session, under no
  policy. A removal of any policy sends an overlapping run to review, which can ask once more than needed. The
  durable policies bullet now says so.
- 2026-11-12: Resolved links in a host launch's folder (work-queue best guess). A launch's folder was compared with the
  approved folder as text. A link inside the approved folder could then lead a covered driver anywhere. Both folders are
  now compared with every link resolved, and a covered driver starts in the resolved folder, so a link changed after the
  check cannot move it. A folder that does not exist is not covered. The links are resolved off the main actor, as
  ADR-08 asks of disk work with no bound, so a covered launch starts a moment after Run. The other option was to cover
  only the approved folder itself, which needs no disk work but drops the folders inside it. Policy containment at
  admission still compares the declared text, since no driver runs there. The host-launch bullet now says so.
- 2026-11-12: Read the clipboard off the main actor for typed requests (work-queue best guess). A script's or a
  driver's typed read asked the general pasteboard on the main actor. An app can supply its text only when asked, so
  the read could wait on another process, which ADR-08 forbids. The read now runs off the main actor, and the grant
  is checked again before any text goes to the program. A typed write still runs on the main actor, since it hands
  the text to the pasteboard server and waits on no other app. The terminal's own paste predates M6 and is left as
  it was.
- 2026-11-12: Refused a linked policy folder and a policy file that is no regular file (work-queue best guess). The
  store made its folder private with a call that follows a link, so a link in its place made the link's target
  private and kept the policies there. A FIFO in the file's place made every read wait forever while it held the
  lock. Both now grant nothing and wait on nothing, and the notice says why.
- 2026-11-12: Found the continuous beeping, and ended a test process whose runner is gone (work-queue best guess).
  Two things went wrong on the night M6's first round ran. A consent test waited, with no deadline, on a question a
  broken denial left unanswered. Its cancelled `swift test` left the test process running, since SwiftPM gives it a
  process group of its own. Separately, the system sound server's log shows about 580 alert sounds in two minutes,
  all from the two app processes of the coordinator's UI run, and none from the hung test process. The new consent
  UI test typed a shell command while Controllers & Permissions or the Pending Requests panel was key. No text view
  took the keys, so each character beeped, and the command never reached the terminal. The UI test now clicks the
  terminal before it types. The package's test bundle now links a small guard that exits when the process that
  started it exits, and the consent tests bound every wait, so a wait that runs out fails and stops its test. A
  cancelled hung run was checked with and without the guard: without it the process stayed, and with it nothing was
  left.
- 2026-11-12: Bounded a driver's clipboard text by its escaped frame (work-queue best guess). M6 bounded a typed exec
  clipboard read or write at 256 KiB of UTF-8 text, and the frame at 1 MiB. JSON escapes a control character to six
  bytes. A 256 KiB text could then need 1.5 MiB. A read's reply could pass the frame bound. A driver's write of such
  text was a line the app's reader refused, which ended the driver. A write past 256 KiB was a malformed message, which
  ended the driver too. The bound is now 128 KiB, an eighth of a frame. A text at the bound fits one frame however it is
  escaped. A longer write whose line fits a frame is refused as `bad-argument`, as that one call, and the channel stays
  up. A line past the frame still ends the driver. The reader refuses it before it learns the request ID, so no reply
  can name the call. A longer clipboard on a read is refused as `failed`, as before. The script wire keeps 32 KiB, half
  of its largest message body. It sends text unescaped in a binary frame. The exec protocol stays at version 3. M6
  introduced the clipboard messages, and none shipped with the old bound. "Exec wire format" now states the bound. It
  named none before. Its Amended marker moved here from the 2026-11-11 entry on drivers that lay out their subtree,
  which is above. The other option was to raise the frame to 2 MiB. That would double the memory a reader may hold for
  one line. If the user wants larger clipboards, the frame would grow with them.
- 2026-11-12: Dropped the bound on kept denials (work-queue best guess). The entry on keeping denials until Ask Again
  said "At most 64 are kept, oldest dropped first." A denial past the 64 newest was then dropped. Its requester was
  asked again with no retry, which "Denial suppresses automatic re-prompting until a local retry" forbids. Each denial
  is a user's Deny on a panel row or a startup review. No program can record one. The user's own pace therefore bounds
  the list. Denials now have no count bound, and none is dropped. A requester's denials still go when it ends. The
  coalescing bullet now says so. The other option refused every new question as busy once 64 denials were kept. Startup
  reviews wait apart from the panel's rows, so that needed one reservation across both. The panel's row bound is also
  64. That option would then refuse ordinary questions as denials built up. If the user wants a bound back, it would be
  that busy refusal, not dropping the oldest.

- 2026-11-16: Superseded in part by UTERM-032. A remembered approval may hold the folder of a run's input file,
  after the sheet showed it, so arguments are no longer always outside a remembered scope. Allow once keeps that folder
  standing for the run beside Janet capabilities. A startup denial of a run with an input folder covers that folder
  only, and a covering approval admits such a run before the denial check.
- 2026-11-16: Superseded in part by UTERM-028. The app's exec hello offers the versions it speaks, and the driver
  answers with one, instead of each side refusing every version but its own. A driver whose own pane is disconnected
  keeps commanding the remote-controlled members it owns, which supersedes in part the 2026-11-11 entry's rule that
  member commands need the driver's pane remote-controlled. Revoke Controller is offered on the pane of a driver that
  holds UTERM-028's command grant, even when the driver owns no group.
- 2026-11-17: Superseded in part by UTERM-026. A program may control panes in its source window and in a window its
  run opened, which holds only panes that run opened, per ADR-14. That window's layout has no anchor and holds only new
  panes. Closing such a window ends the owner's authority there only. Closing the source window still ends it
  everywhere.
- 2026-11-20: Superseded in part by UTERM-036. A layout request's new panes behave as the user's splits, and the last
  new pane takes focus. A layout that makes no new pane moves no focus. This replaces M4's line that a published layout
  leaves focus where it was.

## References

- [ADR-09](../adr/ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): authenticated
  requester, explicit scope, and verified reuse of remembered approval
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): supersedes ADR-09; a controller controls what its
  run opened, across the windows it opened

- [ADR-01](../adr/ADR-01-libghostty-behind-terminal-surface-protocol.md): terminal-engine boundary
- [ADR-02](../adr/ADR-02-pane-tree-nodes-have-stable-ids.md): stable node identities
- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): inert restored state
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): window shortcut ownership
- [ADR-05](../adr/ADR-05-applet-lifecycle-events-and-applet-responses.md): applet lifecycle ownership
- [ADR-06](../adr/ADR-06-layout-file-versioning-and-schema-ownership.md): envelope and applet versioning
- [Apple's Unix socket definitions](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/un.h):
  peer identity
- [Apple's process identity structures](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h):
  parent and process-start identity fields
- [Apple's exec identity update](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c):
  execution generation changes on exec
- [Apple's Unix socket peer lookup](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/uipc_usrreq.c):
  live peer lookup and its limits
- [Janet modules](https://janet-lang.org/docs/modules.html): source, image, and native module loading
- [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259): JSON syntax and UTF-8 interoperability

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, CONTROL-1 to CONTROL-3
  and groups
