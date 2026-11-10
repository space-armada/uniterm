# ADR-10: The App Runs Unsandboxed, and Helpers That Need No File or Network Run Sandboxed

**Status:** accepted
**Date:** 2026-11-07

## Context

uniterm is a terminal. Its shells read and write the user's home folder, start programs, and open network connections.
A process inside the App Sandbox cannot hand its shell the user's home folder, so the terminal would break. UTERM-001
turned the App Sandbox off for the app and made `scripts/check-sandbox-off.sh` enforce it.

UTERM-006 then added the first helper executable: an image decoder that runs ImageIO on files from Downloads and mail.
ADR-07 asks that such work be contained. A separate process contains crashes and hangs, but a decoder exploited by a
crafted file would still run with the user's full privileges. The decoder needs no file or network access, since the
app opens each file and passes it a descriptor. So it runs inside the App Sandbox. UTERM-007 added a second helper on
the same terms, a document decoder for RTF and Word.

UTERM-003 then added the first helper that needs file access of its own: the `uniterm` command, which runs Janet
scripts.

Without a record, the next person to add a helper sees an unsandboxed app and a script named for keeping the sandbox
off, and could ship the helper unsandboxed.

## Decision

The app runs outside the App Sandbox. A helper executable that needs no file or network access of its own runs inside
it.

- A helper of that kind gets its input from the app, such as a file descriptor or bytes over a socket. It holds the
  App Sandbox entitlement and no file, network, or exception entitlement.
- A helper's entitlements file lives outside `App/`. The app target never points `CODE_SIGN_ENTITLEMENTS` at a
  sandboxed file.
- `scripts/check-sandbox-off.sh` checks both halves. The app must not be sandboxed, and each such helper must be, in its
  source entitlements and in the copy signed into a built app. A helper under the last bullet is listed there too, and
  the check confirms that it holds no entitlement, so it cannot pass for a sandboxed one.
- A helper that does need file or network access of its own states why, and what bounds it instead.

## Rationale

The App Sandbox is the strongest containment macOS offers a process uniterm starts. A helper that parses untrusted data
is where an exploit would land. The sandbox turns a code-execution bug in that helper into a process that cannot read a
file or reach the network. A process boundary alone does not.

The app itself cannot take the sandbox without breaking the terminal. Putting each helper that can do without file and
network access inside it gets the protection where the risk is, at no cost to the terminal.

## Consequences

- Each new helper chooses between the sandbox and a stated reason it cannot use it. The check script must learn each
  new helper, inside the sandbox or out.
- A sandboxed helper cannot open a file by path, so the app opens files and passes descriptors. That fixes the shape of
  each helper's protocol.
- Proving a helper's sandbox needs the signed helper running outside any other sandbox. In this project that is
  `make test-helper-sandbox`.
- The `uniterm` command is the first helper under the last bullet. It runs Janet for `uniterm run` and for each REPL
  pane. A run reads its script by path and may be granted file reads. A run and a REPL both reach the app's socket by
  path. Janet's own sandbox, a memory cap per helper, and process isolation bound it instead. See UTERM-003
  "Sandboxing" and "Where scripts run".
- Janet enforces its sandbox inside the process, and macOS does not. A bug in Janet's C code could get past it, where
  the App Sandbox would still hold. A helper under the last bullet trades the App Sandbox for a weaker bound, which is
  why it must state its reason.

## Alternatives Considered

- **Sandbox nothing, and rely on process isolation alone.** ADR-07 contains crashes and hangs this way, but an exploited
  decoder would keep the user's full file and network access.
- **Sandbox the app too.** The terminal needs the user's home folder and arbitrary programs, which the App Sandbox
  forbids.
- **Sandbox the Janet helper and pass it descriptors.** A run takes its script's path on the command line, and a
  script granted file reads opens paths of its own choosing. A REPL starts from a terminal, which can pass it only a
  directory, an environment, and a program. Neither can take its input from the app the way a decoder does.
- **Leave the rule in the check script and UTERM-006 only.** A later helper's author would have to find both to learn
  the rule. The script's name says the opposite of what a helper needs.

## References

- UTERM-001: the App Sandbox off for the app
- UTERM-006: "Rendering", the sandboxed decoder helper
- UTERM-007: "RTF and Word use the system readers", the sandboxed document decoder
- UTERM-003: "Where scripts run" and "Sandboxing", the unsandboxed `uniterm` command
- ADR-07
- `scripts/check-sandbox-off.sh`
