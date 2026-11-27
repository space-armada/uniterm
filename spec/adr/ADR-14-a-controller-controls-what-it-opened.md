# ADR-14: A Controller Controls What It Opened, Within Authenticated Identity and Explicit Scope

**Status:** accepted
**Date:** 2026-11-17

## Context

Programs drive applets, create pane layouts, and request effects such as clipboard access or starting another
program. These effects have different scopes. Permission to update a presentation does not imply permission to read
the clipboard or run an arbitrary executable.

Repeated approval dialogs interrupt legitimate work and encourage habitual approval. Remembering trust avoids those
interruptions, but a saved approval must identify the controller it applies to. A process name, path, or interpreter
executable does not establish which controller code is running. Layout restoration also creates new processes and
pane identities, so it cannot restore a former connection's authority.

ADR-09 limited a grant to one authorized window. A presenter view needs a controller's panes in two windows: the
slides with the demo on the projector, and the speaker notes on the laptop. The notes window is one the controller
opened itself, and it holds only panes the controller opened. What the controller may reach there follows from who
opened it, not from which window it sits in.

What a controller opened holds nothing the user placed there, so controlling it widens no access to the user's own
panes or windows. Keying default control to ownership keeps everything the user made out of reach unless the user hands
it over. ADR-09's one-window rule protected the user's other windows. Ownership protects them the same way, and also
admits a window the controller opened for itself.

Separating identity from permission makes remembered trust useful without turning it into blanket authority.
Separating policy from the live binding lets approval survive legitimate restarts while rejecting stale ownership
and impersonation. Checking the current scope at the effect boundary prevents queued requests from escaping
revocation.

An accidental close of a notes window must not end the talk in the other window, so a close ends only that window's
share. A run that could reopen a window after the user closed it would override the user's choice.

These rules apply across control transports, applets, persistence, and process hosting. They do not depend on a
particular package format, signature representation, or pane-tree implementation.

This is application authorization. It does not provide OS isolation from malicious processes of the same user or
guarantee the behavior of approved code.

## Principles

- **P1**: Ownership sets default control. A controller may control, by default, the windows and panes its run opened.
  Everything else is the user's, and a controller reaches it only through an explicit grant the user makes. Ownership
  defines a grant's targets, never its powers.
- **P2**: A run's targets are the panes it opened, plus the source pane it acts for. Its windows are the source window,
  which holds that source pane, plus the windows the run itself opened. A run never gains a pane or a window by
  position, nesting, or a later user move.
- **P3**: The user may widen a run's targets explicitly, such as by enabling a pane or handing it restored panes. A
  program can never widen them itself.
- **P4**: A window a run opened holds only panes that run opened. Opening a window is a power of its own.
- **P5**: Closing a window the run opened ends the grant's reach into that window only. Closing the source window ends
  the grant. The user's close of an opened window is final for that run.
- **P6**: Revocation ends the grant in every window it reaches.
- **P7**: Every programmatic control effect requires an authenticated requester and an explicit, revocable grant
  covering the operation and its current targets. Identity alone grants no permission.
- **P8**: Pane control, clipboard reads, clipboard writes, runtime capabilities, host-side program execution, and
  opening a window are separate powers. Ownership or one granted power never silently grants another.
- **P9**: A remembered approval is a policy for a verified controller version or identity. Each run establishes a fresh
  authenticated binding to the actual controller and its current target scope. Claimed names, paths, digests, and the
  identity of a shared interpreter are insufficient proof of script identity.
- **P10**: An unchanged or narrower permission request can reuse its approval. Additional powers, broader scopes, or a
  change in permission meaning cannot increase an existing approval without the user's consent. A signing identity
  proves continuity, not permission for every future effect.
- **P11**: Authorization is checked at the effect boundary. Queued work cannot retain authority after its grant is
  revoked or its live requester binding is invalidated. Persisting policy does not persist a connection or live
  ownership.
- **P12**: Remembered permission does not override a user's disconnected pane or confer ownership of restored panes.
  Permission and execution intent remain separate. Restored state never starts a controller automatically, per ADR-03. A
  restored window that a former run opened gives no later run any reach into it.
- **P13**: The claimed requester scope cannot be narrower than the transport can establish. A terminal-session request
  that cannot identify its originating program cannot use a particular script's persistent approval.
- **P14**: A controller whose identity cannot be established across windows cannot hold a grant across windows.
- **P15**: A program's reach is always bounded. Every power and effect a program can use carries a bound on its targets,
  on how long or how often it acts, or on how much of the user's attention it claims. One-use consent is one such bound.
  A standing grant is not. No program may hold any part of the user's screen, input, or attention without limit, whether
  or not it holds a grant. A grant decides whether a program may act, not how much of the session it may take.

## Carve-outs

- **C1** (relaxes P7): An effect that only shows the user something, or asks the user a question and returns the answer,
  needs no grant. It may open its own pane or tab beside the requester and move focus only as the user's own open would.
  It changes nothing else of the user's. It still needs an authenticated requester, and P15 bounds it. What the
  requester does with an answer is a separate effect, and P7 governs it.
- **C2** (relaxes P9): A script run by a shared interpreter may hold a remembered approval when uniterm itself
  snapshots and verifies the script and every file its package declares, and starts the interpreter with a command line
  those verified files fix. No argument comes before the script, and no environment key the interpreter or the loader
  reads as a hook comes from outside the verified files. Settings that change where the interpreter finds its startup
  files, such as `HOME`, are outside what uniterm verifies, and the user is told so. The proof of identity is uniterm's
  own verification, not a name, path, or digest the script or its runner claims. The approval covers only the verified
  files and the access they declare. The interpreter, its install, and whatever the script loads beyond its package are
  outside it, and the user is told so. Verifying files cannot isolate a program from the system it runs on, so the
  approval states its boundary rather than claim one it cannot hold.

## Consequences

- Controllers can repeat approved work without repeated dialogs. A change in authority requires renewed consent.
- Every control entry point uses the same permission boundaries, including applet commands and host-side effects.
- Controller verification and current run binding are necessary before reusing saved approval. A new transport
  cannot treat a controller's self-description as authentication.
- Revocation prevents new authorized effects. It cannot undo external effects an approved program already performed.
- A permission-format or interpretation change cannot silently broaden stored approvals. Unsupported meanings
  authorize nothing.
- A reference to a pane that crosses the control boundary must identify the pane across windows, not only within one.
- Every power and effect a program can use names its bound. One without a bound does not meet P15 until it gains one.

## Alternatives Considered

- **Ask for every effect.** This avoids reusable approval but interrupts ordinary repeated work. It does not make
  habitual approval a sound authorization boundary.
- **Trust a name, path, or interpreter across runs.** Another program or script can share those attributes without
  being the approved controller.
- **Treat trusted identity or pane ownership as blanket permission.** This silently extends approval to unrelated
  powers.
- **Restore live grants with layout state.** The restored processes and panes are new instances. Stored state alone
  cannot establish their authority.
- **Keep one window per grant.** ADR-09's rule. A controller could not reach a notes window it opened for itself.
- **A fresh grant for each opened window.** It adds a prompt mid-setup and contradicts revocation, which ends a run in
  every window.
- **Closing any window ends the whole grant.** An accidental close of a notes window would end the talk, and a rerun
  starts over.
- **Bound every power by a prompt.** A prompt before each status line or question defeats the effect, and trains the
  user to approve without reading.

## Amendments

- 2026-11-21: Numbered the Decision's statements as principles P1 to P14, and moved the Rationale into Context, with
  no change in meaning.
- 2026-11-21: Added P15, that a program's reach is always bounded. A grant decides whether a program may act, not how
  much of the user's session it may take, so the bound needed a principle of its own.
- 2026-11-21: Added C1, which relaxes P7 for an effect that only shows the user something, or asks a question and
  returns the answer. Such an effect takes control of nothing the user holds, and P15 bounds it.
- 2026-11-26: Added C2, which relaxes P9 for a script whose files uniterm itself snapshots and verifies, run with a
  command line those files fix. P9 guards against a program claiming an approved script's identity, and a snapshot
  uniterm verifies is not a claim. The approval covers only the verified files and says so, since no verification of
  files can isolate a program from its system.

## References

- [UTERM-026](../proposals/UTERM-026-screen-control.md): originating proposal, "Authority across windows"
- [ADR-09](ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): superseded by this ADR
- [UTERM-004](../proposals/UTERM-004-control-and-trust.md): controller trust, permission scopes, verified run binding,
  ownership, and saved layouts
- [ADR-02](ADR-02-pane-tree-nodes-have-stable-ids.md): stable node identity
- [ADR-03](ADR-03-restored-state-never-runs-a-program.md): inert restored state
