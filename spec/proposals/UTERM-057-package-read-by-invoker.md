# UTERM-057: Who Reads a Controller Package

**Status:** accepted
**Created:** 2026-11-23
**Updated:** 2026-11-27

## Dependencies

- UTERM-004, for controller packages, `controller.json`, the signature file, and the run snapshot
- UTERM-015, for "The path-reading power", which says a program never borrows uniterm's macOS privacy grants
- UTERM-034, whose "Who reads the script" and "Where the sidecar signature is read" settle the declared-file case
- UTERM-034 M1, for the chunk messages a byte stream rides on. Neither proposal is built. Whichever lands first builds
  them, and the other reuses them.

## Impacts

- UTERM-004 — its controller begin "names … the package path", and the app "independently verifies the artifact".
  "Who opens the package" supersedes that in part. It also supersedes in part "Retain the read-only snapshot for the
  run", for Janet packages. UTERM-004 is implemented, so each takes a "Superseded in part by UTERM-057" marker.
- UTERM-034 — its line "A package keeps its snapshot. It is outside this proposal." This proposal is where that gap
  lands.
- UTERM-056 — any change to the controller begin changes ScriptWire. ScriptWire is at 0 under UTERM-063 and does not
  move, so the change lands in place after UTERM-063 M2, and a native controller built against the earlier begin is
  refused by name. Amended 2026-11-27; see Decision Log.
- UTERM-019, UTERM-029, UTERM-032, UTERM-034, and UTERM-054 — each also changes ScriptWire in place. None moves its
  version.

## ADR Deviations

None. The design meets ADR-08, ADR-13, and ADR-14 P9 as written.

## Summary

Decide who reads a controller package's files when `uniterm run <folder>` or `uniterm controller run <folder>` starts
it. Today the app opens the folder the command names, with uniterm's own macOS privacy grants.

## Motivation

`uniterm run <folder>` and `uniterm controller run <folder>` run a controller package. `uniterm run` checks that the
path is a folder. Both resolve it with `realpath` and send the path in the controller begin (`ControllerCommands.swift`,
`runJanet` and `runNative`). The command never reads the package.

The app opens that folder in `ControllerSnapshot.create`. It opens the last component with `O_NOFOLLOW`, reads
`controller.json` and the optional signature file, and verifies the signature. It walks the folder in `checkTree`,
which refuses any file the descriptor does not list, since an unlisted file could be code the descriptor does not
cover. It copies each listed file into a run folder under uniterm's caches, and checks each file's digest on the bytes
it copied. For a native entry it checks the entry's load commands. Then `verifyCopy` walks and reads the copy again,
and the copy is made read-only.

So the app reads the folder with its own privacy grants. A program outside uniterm's process tree can name a folder it
cannot read itself. It can swap a parent folder for a link after the command resolves the path. It may also name the
folder directly, though the command's own `realpath` runs with the invoker's access and may already be refused there.
The copy lands in a run folder the program can read as the same user. UTERM-015 says a program never borrows uniterm's
macOS privacy grants.

The leak is narrower than the declared-file case. The app copies only the files `controller.json` lists, and each must
match its listed digest. What leaks is a privacy prompt under uniterm's name, whether a protected folder holds a
package, and a copy of a real package the user keeps in a protected place.

The app's read also has no bound. It runs in a detached task with no deadline. A package on a mount that never answers
leaves the admission pending and the command hung. See bug
[20261123-package-admission-read-has-no-bound](../bugs/20261123-package-admission-read-has-no-bound.md).

UTERM-034 fixes the declared-file form: the command reads the file once with the invoker's own access and sends its
bytes, and it reads the `.sig` beside the script itself. It leaves packages out and points at this gap.

Filed from bug
[20261122-package-snapshot-opens-program-chosen-folder](../bugs/20261122-package-snapshot-opens-program-chosen-folder.md).
The trace was confirmed against the tree on 2026-11-23. It was not reproduced, since the result depends on whether
uniterm holds a Documents, Desktop, or Downloads grant on the Mac.

## Design Decisions (Settled)

### Who opens the package

Original question: who opens the package when `uniterm run <folder>` or `uniterm controller run <folder>` starts it?
Today the app opens the folder the command names, with uniterm's own privacy grants.

Decision: the command reads the package and sends its bytes. A Janet package gets no snapshot. Settled 2026-11-23
(autonomous); see Decision Log.

- The command reads `controller.json`, the signature file, and each listed file once, with the invoker's own access.
  It reads them as `ControllerSnapshot` does today: component by component, with `O_NOFOLLOW` and `O_NONBLOCK`, plain
  files only. A link or a FIFO in the package is still refused, per UTERM-004.
- The command sends the bytes in chunks, each within the control-frame cap. `controller.json` and the signature travel
  as the first entries of the same stream. Both `ControllerDescriptor.maxBytes` and `ScriptProtocol.maxControlBody` are
  64 KiB, so the descriptor cannot ride in the begin frame. Its cap stays, so every package valid today stays valid.
- The signature read moves to the command with `controller.json`. An app read from the folder would bring back the
  program-chosen open, as UTERM-034 found for the `.sig`.
- The app reads no chunk before it authenticates the peer as the bundled command. It parses `controller.json` and
  verifies the signature first. It refuses on the descriptor before it accepts any file bytes, for an entry kind that
  does not match the command or an undeclared `--allow`.
- `controller.json` declares no sizes, so the command sends each listed file's byte count with the descriptor, before
  any file bytes. The app refuses a count over the per-file cap, or a sum over the package cap, before it reads a file.
  It refuses a file whose bytes run past or short of its count. A count is a claim the app enforces, never a trusted
  size.
- The app hashes each file as it arrives and checks it against its listed digest. It never takes a digest from the
  command, per ADR-14 P9. The version stays the SHA-256 of `controller.json`.
- A Janet entry gets no snapshot. Once admitted, the command runs the files it read, which it already holds as the
  files map `ScriptVM.runPackage` takes. It checks that the admitted version is the SHA-256 of the `controller.json` it
  sent. That replaces the read-back in `ControllerSnapshot.load`.
- A native entry gets a snapshot that the app writes from the bytes it received, streaming each file to disk and the
  hash. `execve`, the code identity, and `realpath` need the entry on disk. The load check needs whole files, so it reads
  the entry and its libraries back from that copy. Then `verifyCopy` and the lock run as today.
- One deadline, sized for a 128 MiB package, bounds the transfer from the begin until the last listed file verifies.
  Review and the policy lookup start only after that, and the user's review stays unbounded, as today. The app never
  reads a file system the program chose, so no read in the app can block on one.

Rationale: a read in the invoker's process gives the run exactly what the invoker could read, as UTERM-034 settles for a
declared file. One reader and one read make the bytes the app verified the bytes that run. No read in the app touches a
program-chosen file system, which closes bug `20261123-package-admission-read-has-no-bound` and meets ADR-08. Skipping
the Janet snapshot follows one rule for every Janet artifact: a snapshot exists only when something must exec from disk.
This supersedes in part UTERM-004's "Retain the read-only snapshot for the run", for Janet packages.

The other options:

- Bytes, keeping a snapshot for every entry, is equally correct. It keeps a window between the app's `verifyCopy` and
  the command's read-back, where a same-user write turns into a refusal. It adds a caches-disk failure for runs that need
  no disk. It reads up to 128 MiB twice, and a Janet package would differ from a Janet file.
- The command copying into a run folder the app made needs no chunk messages. But the app's digests are not taken on
  bytes it received. The app verifies a folder another same-user process fills, and a mount laid over a subfolder can
  hang `verifyCopy`. The copy step also needs its own deadline.
- Passing one descriptor per file likely carries the invoker's access, though that rests on the same unverified
  attribution as the folder option. The app still reads a program-chosen file system with no bound, which UTERM-034
  rejected and ADR-08 rules out. The socket holds at most 4 unclaimed descriptors, and no ScriptWire code claims one
  today.
- Passing the folder's descriptor likely does not fix the bug. Every `openat` beneath it is made by the app and charged
  to uniterm's grants. Its read also stays unbounded.
- Keeping the app's open and comparing the device and inode, or checking a protected-place list, fails as UTERM-034
  found. The open still raises a prompt under uniterm's name, and the list misses places macOS guards.
- Writing no snapshot for a native entry either needs the app to parse code signatures from bytes. It also breaks
  UTERM-004's rule that a native entry starts from the verified snapshot.
- No rule keeps the bug, and conflicts with UTERM-015.

### Where the unlisted-file check happens

Original question: today `checkTree` walks the source folder in the app and refuses any file `controller.json` does not
list. Under "Who opens the package" the app no longer sees the source folder. Where does that check happen?

Decision: the command runs the existing tree check on the source folder before it sends any file bytes. Settled
2026-11-23 (autonomous); see Decision Log.

- The walk and every file read use one opened directory descriptor, as `ControllerSnapshot.create` does today. A parent
  swapped between two opens cannot make the command check one folder and read another.
- A package with a file it does not list, such as a Finder `.DS_Store`, is refused before admission, as today. A link or
  special file at an unlisted path is still refused, so the settled link rule holds for the whole package.
- The check is the enforcement, not a pre-check. It runs in the bundled command, which the app already trusts to read
  the package. The app separately refuses a stream that is missing a listed file, carries an extra one, or fails a
  digest.

Rationale: run and `controller sign` keep one rule, since `sign` already refuses an unlisted file. A forgotten listing
fails with its name before any code runs, not later when an import panics. Unlisted code has no path into a run either
way: the Janet loader resolves imports only from the files map, and a native snapshot holds only listed files.

The other options:

- Dropping the source check admits a package whose entry imports a file the author forgot to list. The run then fails
  late, at the import, after any pane effects it made first. It also drops the refusal of a link at an unlisted path,
  and run and `sign` would disagree.
- Dropping the check in both run and `sign` keeps them agreeing, but it changes `sign`, which is outside this proposal.
  It loses the early refusal too.
- Having the command report a listing for the app to compare adds a wire field. The app could only catch a command that
  lies, and it already trusts that command's reads.

### Version skew

Original question: the controller begin is a ScriptWire message, and the command and the app ship in one bundle. How
does the change land across versions, beside UTERM-056?

Decision: ScriptWire is at 0 under UTERM-063 and does not bump. The controller begin changes in place, after UTERM-063
M2. The old path-based begin is a retired message, and the app refuses it by name. Settled 2026-11-23 (autonomous).
Amended 2026-11-27; see Decision Log.

- Only the bundled command sends the controller begin. A native entry's own connections are adopted, never begun. So
  the begin's change crosses only the command and the app, which ship in one bundle. ADR-13 P6 lets the command's
  own messages refuse every version but their own.
- Old command to new app: the old command's path-based begin is refused by name with an explicit refusal, never
  admitted. A swapped bundle is caught by the command's identity check, which says to relaunch uniterm. New command to
  old app: the old app's strict decoder refuses the message it does not know. No deploy order is needed. A revert and a
  redeploy undo the change.
- The new app keeps no path-based admission, so an old command can never bring back the program-chosen open.
- No stored data changes. A package's version stays the SHA-256 of `controller.json`, so earlier approvals still apply.
- A native controller built against the earlier begin is refused by name, and rebuilt. See Risks.
- UTERM-019, UTERM-029, UTERM-032, UTERM-034, and UTERM-054 also change ScriptWire in place, and none bumps it.

Rationale: a retired message refused by name gives both directions a clear error, and the version stays 0 under
UTERM-063.

The other options:

- A new begin message that an old app does not refuse by name fails its own skew analysis. A new command against an old
  app then closes on an unknown type, and the user reads "closed the connection before the script began". UTERM-063 M2
  makes every decoder refuse by name, which removes that failure.
- Waiting on UTERM-056 before landing spares native controllers. But it holds up a confirmed privacy fix for programs
  nobody is known to run.

## Design Decisions (Open)

None.

## Risks

- **macOS may charge the command's reads to uniterm** — likelihood: medium, impact: high. The bundled command runs from
  inside uniterm's bundle. If macOS attributes its file reads to uniterm rather than to the process that started it,
  the command's own read borrows uniterm's grants. The evidence does not settle the likelihood, so it takes the higher
  rating. UTERM-034 carries the same risk. Mitigation: M1 carries the same manual check UTERM-034 M1 does, run on a Mac
  where uniterm holds a Documents grant and the invoking program does not. If that check fails, M1 is not done, and a
  follow-up proposal picks a reader that macOS charges to the invoker, for both this proposal and UTERM-034.
- **A large package moves a large transfer onto the socket** — likelihood: medium, impact: low. UTERM-034's single
  deadline from begin to declaration is sized for one script, not for 128 MiB on a slow disk. Mitigation: the package
  size is already bounded by `ControllerDescriptor.maxPackageBytes`. M1 names a deadline sized for it. The app refuses
  on the descriptor before it accepts file bytes, and streams each file to disk and the hash rather than holding the
  whole package.
- **Native controllers built against the earlier ScriptWire are refused** — likelihood: low, impact: medium. The
  retired begin is refused by name. Accepted: no program on them is known outside the test fixture, and UTERM-054
  accepts the same refusal. A native controller is rebuilt.
- **Several proposals change the same wire in place** — likelihood: medium, impact: low. UTERM-019, UTERM-029,
  UTERM-032, UTERM-034, and UTERM-054 each change ScriptWire. Mitigation: ScriptWire stays at 0, each change takes a
  new name when its meaning changes, and the strict decoders refuse any name they do not know.
- **The chunk messages are designed for one file** — likelihood: medium, impact: low. UTERM-034 M1 designs them for a
  declared script. A package needs many files and a descriptor in one stream. Mitigation: whichever proposal lands
  first builds them for both. UTERM-034 M1 checks that its chunks carry a package, and this M1 checks that the package
  and the declared file share one mechanism.

## Milestones

### M1: The command reads a controller package

**Status:** NOT STARTED

The app never opens a path for a controller package, its descriptor, or its signature.

- A Janet package runs from the bytes the command read once, and no file is written under the runs root for it,
  admitted or refused
- A native package runs from a snapshot the app wrote from the bytes it received, and the load check, `verifyCopy`, and
  the lock run on that copy
- The command reads each file component by component with `O_NOFOLLOW` and `O_NONBLOCK`, and refuses a link, a FIFO, or
  a special file anywhere in the package, listed or not
- The tree walk and every file read use one opened directory descriptor, and a package with an unlisted file is refused
  with that file's name before any file bytes are sent
- The app reads no chunk before it authenticates the peer as the bundled command
- The app refuses on the descriptor before it accepts file bytes, for an entry kind that does not match the command or
  an undeclared `--allow`
- The app refuses a byte count over the per-file cap, or a sum over the package cap, before it reads any file, and
  refuses a file whose bytes run past or short of its count
- The begin carries the entry kind and the `--allow` names with no path, and the admitted reply names a snapshot only
  for a native entry
- The listener reads no frame after the begin until the peer is authenticated, reads no file-byte frame until the
  descriptor, the signature, and the counts are checked, and reads each next chunk only after the previous one is
  hashed, and written for a native entry
- A descriptor listing 512 files at the longest allowed path, with its counts, passes, and a count list whose paths do
  not match the listed files is refused
- Hashing and snapshot writes run off the main actor
- Review and the policy lookup start only after every listed file has verified
- A refusal, a stall, or a close mid-stream removes the partial run folder, and a crash leaves it only until the next
  launch's cleanup
- The native load check reads from the written copy before the lock, sees every listed path, and checks the bytes it
  reads against their digests, so a packaged library beside a system candidate is never skipped unchecked
- The app refuses a stream that is missing a listed file, carries an extra one, or sends a file whose bytes fail its
  digest, and it never takes a digest from the command
- A `controller.json` at the 64 KiB cap, with a signature, travels in the stream, and every package valid today still
  runs
- A signed package verifies in the app over the bytes it received, a missing signature runs as unsigned, and an
  unreadable or bad one refuses the run
- One deadline, sized for a 128 MiB package and named in the As built block, bounds the transfer from the begin until
  the last listed file verifies, a stalled transfer is refused and its bytes dropped, and a review left open past that
  deadline is not refused
- The app holds no more than one chunk of a file in memory while it writes and hashes it
- When the app refuses while the command is still sending, the command reports the app's refusal text, never a
  broken-pipe or connection error, and never blocks writing into a socket the app has stopped reading
- The command refuses to run when the admitted version is not the SHA-256 of the `controller.json` it sent
- A test that swaps a parent folder for a link after the command's read shows the run uses the bytes the command read,
  and the app opens nothing
- The package stream and UTERM-034's declared-file stream use one chunk mechanism
- An older command and a newer app, and the reverse, refuse each other by name before any effect, and a swapped bundle
  is caught by the command's identity check
- An older command's path-based begin gets an explicit refusal, never admission
- Earlier approvals of a package still apply to the same `controller.json`
- `uniterm run <folder>` and `uniterm controller run <folder>` both take the new path
- The user runs a package in Documents from a program started outside uniterm, on a Mac where uniterm holds a
  Documents grant and that program does not. It passes when the read is refused, or when a privacy prompt names the
  launching program. It fails when the prompt names uniterm, or when the read succeeds with no prompt
- The `ControllerBegin` doc comment says the command reads and sends the package, and UTERM-004 carries "Superseded in
  part by UTERM-057" markers on its begin text and on each passage that puts a Janet run in a snapshot, its As built
  block included
- The bugs `spec/bugs/20261122-package-snapshot-opens-program-chosen-folder.md` and
  `spec/bugs/20261123-package-admission-read-has-no-bound.md` are closed by this milestone's commit

## Decision Log

- 2026-11-23: Filed as a draft from bug `20261122-package-snapshot-opens-program-chosen-folder`. The user asked for a
  new proposal at its triage, over adding packages to UTERM-034. The bug's two fix options became candidates under
  "Who opens the package", and "No rule" was added as the plain behavior. The tree check and signature read became a
  follow-up question, and version skew became a third.
- 2026-11-23: Design critique. Added three candidates under "Who opens the package": bytes with no Janet snapshot, the
  command copying into an app-made folder, and one descriptor per file. Labeled what each candidate leaves undone. The
  folder-descriptor candidate is now marked as likely still charged to uniterm's grants. That is not confirmed. Moved
  the signature read out of the second question, since the bytes candidates force it to the command, and renamed that
  question. Added candidates to the unlisted-file and version-skew questions. Noted the 64 KiB descriptor cap that
  matches the frame cap. Added the macOS attribution risk and the unbounded-read risk, and filed bug
  `20261123-package-admission-read-has-no-bound`. Added UTERM-004 and the other ScriptWire bumps to Impacts, UTERM-034
  M1 to Dependencies, and `uniterm controller run` to the scope. Nothing was settled.
- 2026-11-23: Review start: 0 milestones, 0 settled decisions, 3 risks, no `Live after` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the three open questions, at the commit "Fold
  the design critique into UTERM-057".
- 2026-11-23: (autonomous) Who opens the package: the command reads the package and sends its bytes, and a Janet
  package gets no snapshot. Converged in 1 pass. The invoker's read gives the run only what the invoker can read, and
  no app read touches a program-chosen file system. Supersedes in part UTERM-004's "Retain the read-only snapshot for
  the run" for Janet packages.
- 2026-11-23: (autonomous) Where the unlisted-file check happens: the command runs the existing tree check on the
  source folder before it sends. Converged in 1 pass. Run and `controller sign` keep one rule, and a forgotten listing
  fails before any code runs.
- 2026-11-23: (autonomous) Version skew: ScriptWire's version goes up. Converged in 1 pass. Both directions get the
  relaunch text, and each version keeps one meaning. Under UTERM-056 an old command's path begin is refused.
- 2026-11-23: (autonomous, addition) Closing bug `20261123-package-admission-read-has-no-bound` joins M1. The design
  critique found it, and "Who opens the package" removes the app's read, so it closes with the same change.
- 2026-11-23: (autonomous) Wrote M1 as one milestone, since landing Janet and native packages apart would leave one
  of them on the path-based begin. Revised Risks: added the native-controller refusal as accepted, the shared wire
  version, and the single-file chunk design. Removed the unbounded-read risk, since the app no longer reads a
  program-chosen file system.
- 2026-11-23: (autonomous) Coherence review. The deadline now ends when the last listed file verifies, not at
  admission, since admission follows the user's review and that wait stays unbounded. Was: "bounds the exchange from
  the begin to admission". The command now sends each file's byte count with the descriptor, since `controller.json`
  declares no sizes. Was: the app refuses "a declared size over the per-file or package cap". The load check now reads
  from the written copy, since it needs whole files. Seven implementation findings became M1 checks. The attribution
  risk gained a recovery path. ADR Deviations now says none, with its reason.
- 2026-11-23: (autonomous) Re-check pass converged with no design-level finding. Three implementation findings became
  M1 checks: the listener's read order, a count list for the largest descriptor, and a load check over every listed
  path that verifies what it reads back. Risk review found the Risks section compliant, with no high-likelihood,
  high-impact risk.
- 2026-11-23: Review gate: kept all. The user kept closing bug `20261123-package-admission-read-has-no-bound` in M1,
  and chose to amend UTERM-034 M1 with a check that its chunk messages carry a package too.
- 2026-11-23: ADR candidate (cuts across the system): a file a program names reaches uniterm only through a read with
  the program's own access, so a program never borrows uniterm's macOS privacy grants. UTERM-032, UTERM-034, and this
  proposal each apply it, and no ADR records it. Waits on the manual attribution check in UTERM-034 M1 or this
  proposal's M1, since a failed check changes which process reads.
- 2026-11-23: Accepted.
- 2026-11-24: Scheduled as M1 in queue.md.
- 2026-11-27: From UTERM-063. ScriptWire is at 0 and does not bump, so the controller begin changes in place after
  UTERM-063 M2, and the old path-based begin is refused by name.
  - Amended "Version skew". It said "ScriptWire's version goes up", and that both directions refuse "at the hello with
    the relaunch text, under today's exact match".
  - Amended the Impacts lines for UTERM-056 and the proposals that also bump ScriptWire, and the two risks on native
    controllers and on several proposals bumping one version.

## References

- [UTERM-034](UTERM-034-script-file-read-by-invoker.md): the declared-file precedent
- [UTERM-015](UTERM-015-cross-applet-file-opening.md): "The path-reading power"
- [UTERM-056](UTERM-056-native-controllers-across-scriptwire-versions.md): native controllers across ScriptWire
  versions
- Bug [20261122-package-snapshot-opens-program-chosen-folder](../bugs/20261122-package-snapshot-opens-program-chosen-folder.md)
- Bug [20261123-package-admission-read-has-no-bound](../bugs/20261123-package-admission-read-has-no-bound.md)
