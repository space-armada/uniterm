# UTERM-034: Who Reads a Script File

**Status:** accepted
**Created:** 2026-11-19
**Updated:** 2026-11-27

## Dependencies

- UTERM-003, for `uniterm run`, the command, and the wire between the command and the app
- UTERM-015, for "The path-reading power", which says a program never borrows uniterm's macOS privacy grants
- UTERM-021, for a declared file's snapshot, hash, and sidecar signature
- UTERM-032, for the precedent that the command reads the input file with the invoker's own access

## Impacts

- UTERM-021 — "The file is snapshotted and hashed": supersedes it in part. The command reads the file and the app
  hashes the bytes it receives. A declared file has no snapshot. UTERM-021 is implemented, so it gains a "Superseded in
  part by UTERM-034" marker when this proposal is accepted.
- UTERM-021 — "Where the declaration is read" and "Authority comes from the read, not the run": supersedes them in part.
  The app no longer reads the file or answers with a snapshot. The command parses the bytes it sent.
- UTERM-021 — M2's checks that the command runs the snapshot and refuses a snapshot whose hash differs, and M3's
  As built note that the app reads the `.sig`: superseded in part. They gain the same marker.
- UTERM-003 — "Where scripts run": a declared script reaches the app as bytes from the command, not as a path.
- UTERM-032 — "How the text reaches the script": this proposal applies the same rule to the script file itself.
- UTERM-032 — "Which argument is the input file" and "How the text reaches the script": both speak of the snapshot's
  declaration. UTERM-032 is queued first and builds against the snapshot. M1 here amends both sections to the
  declaration the command reads, with the folder riding on the declaration that follows the bytes.
- UTERM-032 — "Version skew": both proposals change ScriptWire in place. ScriptWire is at 0 under UTERM-063 and does not
  bump. Amended 2026-11-27; see Decision Log.

## Summary

Closes a gap where the app opens a script path that the program chose. The app reads with its own macOS privacy
grants, so the copy can hold a file the program could not read itself.

## Motivation

The command reads a script once, with the invoker's access, to tell a declared file from an undeclared one. For a
declared file it then resolves the path and sends it in the file begin. The app opens that path again, with its own
macOS privacy grants, and copies it into a declared file's snapshot before the user reviews anything. The snapshot
lands in a run folder under uniterm's caches. It is read-only, but the program runs as the same user and can read it.

A program without uniterm's grants cannot name `~/Documents/secret.txt` directly. The command's own read fails first.
It can win a race instead. It runs `uniterm run /tmp/a/secret.txt` on a declared file it wrote. After the command
resolves the path, it renames `/tmp/a` and puts a link to `~/Documents` in its place. The app's open follows the link,
since it refuses a link only in the last component. The app copies the protected file. The command then refuses the
copy as undeclared. But the program can stop the command before that, which keeps the copy until the declaration
times out. The program reads it in that time.

UTERM-015 rules this out for path reads. UTERM-032 rejected a host call for the same reason, and made the command read
the input file with the invoker's access. The script file itself was left on the old path.

The cause is traced in the code, not run. The grant difference needs a Documents grant for uniterm and none for the test
program. Amended 2026-11-22; see Decision Log.

Existing tests copy arbitrary absolute paths on purpose, so none of them covers this.

## Design Decisions (Settled)

### Who reads the script

Original question: the app must not open a path the program chose, with the app's grants. Who reads the script file?

Decision: the command reads the file once, with the invoker's own access, and sends its bytes to the app. The app never
opens a path for a declared file. Settled 2026-11-22 (autonomous), amended the same day; see Decision Log.

- The command reads the script once, as its routing read does today, within the declared-file cap. Its routing between
  a declared and an undeclared file uses those bytes, so the routing and the run cannot see two versions of the file.
  An undeclared script may still come from a pipe, as today.
- A declared file must be a regular file, per UTERM-021. The command checks the descriptor it read. A declared file
  from a pipe, a device, or a path under `/dev` is refused once routing finds the declaration, before anything is sent.
- The file begin carries the file's name for display, the byte count, and the signature bytes. The script's bytes follow
  in chunks, each within the control-frame cap. The app reads a chunk only after it has authenticated the peer as the
  bundled command, and only up to the byte count in the begin. It refuses a begin whose count is over the cap before it
  reads any chunk. A connection that sends more or fewer bytes than it announced is refused.
- The command parses the declaration from the bytes it read, and sends it right after the last chunk. One deadline, from
  the begin to the declaration, bounds the whole exchange. The app no longer answers with a snapshot and a version
  before the declaration, since the command no longer checks a copy.
- The app hashes the bytes as they arrive. The version is the SHA-256 of the whole file, as before. It never takes a
  digest from the command, per ADR-14 P9.
- No declared-file snapshot is written. Nothing but the command ever read it, and the command already holds the bytes it
  sent. It runs exactly those bytes once admitted.
- A package keeps its snapshot. It is outside this proposal. The same gap for packages is filed as a bug, see
  `spec/bugs/20261122-package-snapshot-opens-program-chosen-folder.md`, and its design is in
  [UTERM-057](UTERM-057-package-read-by-invoker.md).

Rationale: a read in the invoker's process gives the run exactly what the invoker could read. This is UTERM-032's rule,
applied to the script file. One reader and one read make the routing, the hash, and the run agree by construction. No
read in the app can block on a slow or hostile file system. UTERM-032's rationale reads ADR-08 as ruling such a read
out of the app.

The other options:

- Passing the command's open descriptor to the app is equally correct. It reuses FramedSocket's descriptor passing. But
  the app still does the read, on a detached task with no bound. A file on a mount the user controls can answer the
  command's read and hang the app's. It also needs the app to read from offset 0, since the routing read leaves the
  shared offset at the end.
- Keeping the app's open behind UTERM-015's protected-location list fails twice. The list does not cover every place
  macOS guards. With Full Disk Access given to uniterm, a swap to a Mail file passes the check. It also refuses a script
  kept in Documents for an invoker who can read it.
- Keeping the app's open and comparing the device and inode the command read closes the content leak. The app still
  opens the swapped path with its grants. That can raise a privacy prompt under uniterm's name, and its open error tells
  the program whether a protected path exists.
- Having the command send only the hash and the declaration leaves the app trusting a digest it did not compute. A
  parser exploit in the command could claim a trusted version's hash for a file it cannot read.

### Where the sidecar signature is read

Original question: the app opens `<script>.sig` from the same program-chosen path. Read it in the command and send it
beside the script bytes, or read it in the app beside a path the command has already vouched for?

Decision: the command reads the `.sig` beside the script's resolved path, with the invoker's own access, and sends its
bytes in the file begin. The resolved path is where `uniterm controller sign` writes it, so a signed file run through a
link still verifies. The app parses it and verifies it over the bytes it hashed. Settled 2026-11-22 (autonomous); see Decision Log.

- The command treats a missing `.sig` as an unsigned file. Any other failure to read one refuses the run, as the app's
  read does today. A `.sig` that is present and does not verify still refuses the file, and never falls back to
  unsigned, per UTERM-021 "Signing".
- The signature cap of 4 KiB fits in one control frame.
- The command reports bytes, never a verified flag. The app verifies, per ADR-14 P9.

Rationale: under "Who reads the script" the app opens no path for a declared file. Reading the `.sig` in the app would
bring back the program-chosen open, after the script's read, for the same swap.

### Whether a refused run keeps its snapshot

Original question: a refused run may leave a copy under Application Support. If it does, say when it is deleted.

Decision: no change needed. Settled 2026-11-22 (autonomous); see Decision Log.

- Today every refusal removes the run folder. Connection close, host stop, and the next launch remove the rest. Only a
  crash of the app leaves a folder, until the next launch.
- Under "Who reads the script" a declared file writes no snapshot, so nothing is left to keep.

### Version skew

Decision: the file begin changes, and chunk messages are new. ScriptWire is at 0 under UTERM-063 and does not bump, so
both land in place after UTERM-063 M2. The old begin is a retired message, and the app refuses it by name. Settled
2026-11-22 (autonomous). Amended 2026-11-27; see Decision Log.

- The command and the app ship in one bundle. ADR-13 P6 lets the command's own messages refuse every build but their
  own. An older command's begin is refused by name before the script's bytes are sent. An older app's strict decoder
  refuses the new begin and chunk messages by name. A swapped bundle is caught by the command's identity check, which
  says to relaunch uniterm.
- No deploy order is needed. A revert and a redeploy undo the change.
- UTERM-032 and UTERM-029 also change ScriptWire in place, and neither is built. None of them bumps its version.
- No stored data changes. The trust store keys a file's approvals by its version, which stays the SHA-256 of the whole
  file, so earlier approvals still apply.

## Design Decisions (Open)

None.

## Risks

- **A slow or hostile file blocks the read** — likelihood: low, impact: low. A file on a network mount or a local
  file-system server can stall a read. Mitigation: the read runs in the command, which the invoker started and can
  stop. The app only waits on a connection, and one deadline bounds the exchange from the begin to the declaration.
- **A large file begin makes the app hold memory before it trusts the peer** — likelihood: low, impact: low. Any
  same-user process can connect. Mitigation: the app reads chunks only after authenticating the peer, each within the
  control-frame cap, and refuses a byte count over the cap from the begin alone.
- **UTERM-032, UTERM-029, and this proposal change the same wire in place** — likelihood: medium, impact: low. Two
  changes could take the same message name. Mitigation: each change takes its own new message name, and the decoders
  refuse a name they do not know, so a clash fails by name. Amended 2026-11-27; see Decision Log.
- **macOS charges the command's read to uniterm instead of to the program that started it** — likelihood: medium,
  impact: high. The evidence does not settle the likelihood, so it takes the higher rating. The fix assumes the bundled command's reads are checked against the privacy grants of the process that launched
  it, not of the app bundle it sits in. If not, the command's own read borrows uniterm's grants with no race at all.
  UTERM-032 rests on the same assumption. No code test can show it. Mitigation: M1 carries a manual check on a Mac where
  uniterm holds a Documents grant and the launching program does not.

## Milestones

### M1: The command reads a declared file

**Status:** NOT STARTED

The app never opens a path for a declared script file or its signature.

- A declared file runs from bytes the command read once, and the app's version is the SHA-256 of the bytes it received
- The command refuses a file over the cap on every read, and refuses a declared file from a FIFO, a device, or a path
  under `/dev` once routing finds the declaration, before sending anything
- The app refuses a begin whose byte count is over the cap, and a connection that sends more or fewer bytes than its
  begin announced
- An undeclared script read from a pipe still runs
- An exchange that stalls between the begin and the declaration is refused after one deadline, and its bytes are dropped
- A peer that is not the bundled command is refused with its chunks still unread in the socket
- When the app refuses while the command is still sending chunks, the command reports the app's refusal text, never a
  broken-pipe or connection error, and never blocks writing into a socket the app has stopped reading
- A signed file verifies in the app over the received bytes, a missing `.sig` runs as unsigned, and an unreadable or bad
  one refuses the run
- A signed file run through a link to it verifies with the `.sig` beside the link's target
- No file is written under the runs root for a declared file, admitted or refused, and its admission names no path
- The review's title comes from the begin's name, the resolved file's last component, cleaned as today
- A test that swaps a parent folder for a link after the command's read shows the run uses the bytes the command read,
  and the app opens nothing
- An older command's file begin is refused by name before the script's bytes are sent, and an older app refuses the
  new messages by name. Amended 2026-11-27; see Decision Log
- The chunk messages can also carry a controller package's descriptor, signature, per-file byte counts, and many files
  in one stream, so UTERM-057 reuses them and builds no second mechanism
- Earlier approvals of a file still apply to the same bytes
- The user runs a declared file in Documents from a program started outside uniterm, on a Mac where uniterm holds a
  Documents grant and that program does not. It passes when the read is refused, or when a privacy prompt names the
  launching program. It fails when the prompt names uniterm, or when the read succeeds with no prompt
- When UTERM-032 has landed, its input-file mark and folder come from the bytes the command read, and its sections
  "Which argument is the input file" and "How the text reaches the script" and its snapshot check are amended to match
- The bug `spec/bugs/20261116-script-snapshot-reads-program-chosen-path.md` is closed by this milestone's commit

## Decision Log

- 2026-11-19: Filed from a bug, which found the app reading a program-chosen script path. The bug is
  `spec/bugs/20261116-script-snapshot-reads-program-chosen-path.md`.
- 2026-11-22: Review start: 0 milestones, 0 settled decisions, 3 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the three open questions. Baseline is the commit
  "File UTERM-034 for who reads a script file, so the app never opens a path the program chose".
- 2026-11-22: Motivation corrected. It said a program can name `~/Documents/secret.txt` directly and the copy lands under
  Application Support. The command's own routing read fails first for an invoker without access, so the leak needs a
  parent-folder swap after the command resolves the path. The copy lands under uniterm's caches. The attacker is a
  program outside uniterm's process tree, since processes uniterm starts hold its grants already. Option B also said the
  protected-location list was unbuilt. UTERM-015 M4 built it.
- 2026-11-22: Who reads the script: the command reads the bytes once with the invoker's access and sends them in chunks
  accepted only after the peer is authenticated. The app hashes them, and no declared-file snapshot is written. Chosen
  over passing the descriptor, which keeps an unbounded read in the app. (autonomous)
- 2026-11-22: Where the sidecar signature is read: in the command, sent as bytes, verified by the app. Follows from the
  app opening no path. (autonomous)
- 2026-11-22: Whether a refused run keeps its snapshot: no change needed. Every refusal, connection close, host stop,
  and launch removes it today, and a declared file now writes none. (autonomous)
- 2026-11-22: Version skew: ScriptWire's version goes up, and each side refuses any other at the hello. No deploy order.
  The risk that called the wire change a one-way door is replaced, since a revert undoes it. The two risks that applied
  only to the protected-location option are dropped with that option. (autonomous)
- 2026-11-22: Who reads the script, amended in the coherence review. It said the command's open refuses a FIFO, a
  device, or a path under `/dev` before routing. That would refuse an undeclared script from a pipe, which runs today.
  Now only a declared file must be regular, checked after routing, per UTERM-021. Dropping the rule for declared files
  too was weighed and not taken, since it would let a declared file come from a pipe. (autonomous)
- 2026-11-22: Who reads the script, amended in the coherence review. The command sends the declaration right after the
  bytes, under one deadline. The app's answer with a version before the declaration is dropped, since only the command's
  check of the copy used it. (autonomous)
- 2026-11-22: Where the sidecar signature is read: beside the resolved path, where signing writes it. (autonomous)
- 2026-11-22: Risk added: the fix assumes macOS charges the command's reads to the program that launched it. Rated low
  likelihood, high impact, mitigated by a manual check in M1. (autonomous)
- 2026-11-22: Coherence review converged after a full pass and one re-check pass. Four findings were routed to M1
  checks: the routing read's refusals, a refusal while the command still sends chunks, the manual privacy check's
  pass and fail results, and the `.sig` beside a link's target. (autonomous)
- 2026-11-22: Risk review: every risk carries a likelihood, an impact, and a mitigation. No one-way door remains, since
  the hello refuses every other wire version and no stored data changes. No risk is high likelihood and high impact.
  (autonomous)
- 2026-11-22: The same gap for packages is filed as
  `spec/bugs/20261122-package-snapshot-opens-program-chosen-folder.md`, not added to this proposal. (autonomous)
- 2026-11-22: Review gate: kept all. The user kept UTERM-021's refusal of a declared file that is not a regular file or
  is named under `/dev`, over dropping the `/dev` rule or allowing any readable source.
- 2026-11-22: ADR candidate (cuts across the system): uniterm never reads a file for a program with its own macOS
  privacy grants, so a program's reads carry at most the invoker's access. Declined: UTERM-015 "The path-reading power"
  and UTERM-032 state it, and this proposal cites them.
- 2026-11-22: Accepted. UTERM-021 gains "Superseded in part by UTERM-034" markers. UTERM-032 is queued first and keeps
  its text, and gains an Impacts note. M1 here amends UTERM-032's input-file sections when it builds the change.
- 2026-11-22: The privacy-attribution risk is re-rated from low to medium likelihood. Nothing was run, and the critic
  could not rule the other attribution out, so it takes the higher rating. It is not high on both, so it does not block
  acceptance. The M1 manual check can run before M1 is built. (autonomous)
- 2026-11-22: Scheduled as UTERM-034 M1 in queue.md, after UTERM-032 M1-M2.
- 2026-11-23: M1 gains a check that its chunk messages also carry a controller package, for UTERM-057. Its design
  streams a package's descriptor, signature, byte counts, and files over the same chunks. Adding the check while M1 is
  unbuilt keeps one mechanism for both.
- 2026-11-23: From UTERM-056's acceptance. "Version skew" and M1's check said each side refuses any other version "at the
  hello". UTERM-056 moves an older command's refusal to its begin.
- 2026-11-27: Brought in line with UTERM-063 at the user's direction. "Version skew" said "the file begin changes, and
  chunk messages are new, so ScriptWire's version goes up". It said an older command and a newer app "refuse each other
  before the script's bytes are sent, at the hello, or at the begin once UTERM-056 has landed" with a relaunch message,
  and that UTERM-032 and UTERM-029 "bump ScriptWire's version... Whichever lands later bumps again". The Impacts line,
  the risk "bump the same wire version", and M1's check on an older command said the same. ScriptWire stays at 0, so the
  change lands in place. The old begin is refused by name. A swapped bundle is caught by the identity check.

## References

- ADR-13: ScriptWire may refuse every version but its own
- ADR-14 P9: claimed digests are no proof of script identity, so the app hashes the bytes itself
- UTERM-015 "The path-reading power": a program never borrows uniterm's macOS privacy grants
