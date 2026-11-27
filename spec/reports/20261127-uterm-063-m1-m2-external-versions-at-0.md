# UTERM-063 M1-M2: external versions stay at 0

Started 2026-11-27, as the fifth row of the day's second `/work-queue` run of `next 6`. The run's state is in
[the UTERM-044 M3 re-check report](20261127-uterm-044-m3-failed-shard-reruns-alone-recheck.md). Every commit is in this
repo, on `agent/petunia`.

The row has no dependencies and no `Live after` line. Its base is "Log a second batch of 40 shortcut test runs with no
Cmd-T stall".

## Best guesses from the plan

- The trust stores' format moves 1 → 2 in M1, for both `policy.json` and `files.json`, which share one codec. M1's own
  check must set a pre-reset file aside by its format. UTERM-067's risk "Every approval is given again once" already
  accepts the break twice, in either order. UTERM-067 M2 later moves the format to 3. If wrong, M1 would keep format 1
  and could not tell a pre-reset file apart.
- Editions: an approval at an older edition reads but does not cover, so the user is asked again. An edition above this
  build's reads the file as newer until UTERM-067 M2 narrows that to one entry. Source: "Permissions carry no version"
  and M1's check that an older edition "no longer covers it".
- The declared-stable list is `spec/declared-stable-versions.md`. M1 says only that it lives in the repository.

## UTERM-063 M1

### What was built

- ScriptWire, the exec wire, the four registered command schemas, the descriptor format, and `uniterm/api-version` are
  at 0 and 0.0. Their docs say so. DocumentWire and ImageWire are unchanged.
- Descriptors name each permission by kind. One that names a version is refused by name. Each kind has an edition, all
  at 0, kept in an injectable table. A stored scope records its edition.
- The trust stores' format is 2. A format 1 `policy.json` or `files.json` is set aside with a notice that each approval
  is given again once.
- A hello at another exec protocol version decodes to its own case, with no schema, so its 0.0 placeholder can never
  reach the schema check.
- Every fixture speaks version 0, the test-only applets and `driver.pl` included. The `janet-hello` package was
  re-signed with a throwaway CryptoKit program, after it reproduced the old digest and fingerprint.
- `scripts/check-external-versions.sh` runs in `make check`, with a self-test. It reads the named constants, and fails on
  any schema construction it cannot read. The declared-stable list is `spec/declared-stable-versions.md`, empty, and
  `CLAUDE.md` names it.
- ADR-13 carries the user-approved C1, P5, and Amendments line, and says "external wire". ADR-16's consequence line and
  ADR-18's wording follow. `docs/glossary.md` has "Wires and versions" with the five entries.
- Impacted proposals were amended in place: UTERM-006, 019, 024, 026, 029, 030, 032, 040, 048, 050, 054, 057, and 062.
  UTERM-028, 055, 056, and 064 already carried UTERM-063's text. ADR-13 reference labels in UTERM-028, 043, 054, 055,
  056, 062, and 065 now say "external wires".

### Pending overrides

Three amended decisions carry `**Decided by:** user`. Their text was left as the user wrote it. Each gained a
`**Pending override:**` line that cites UTERM-063's user decision of 2026-11-26:

- UTERM-019 "Widened browser read and browser navigation" (user, 2026-11-11): permissions name a kind and an edition,
  not a version
- UTERM-019 "Permission descriptor format" (user, 2026-11-11): the same
- UTERM-050 "What `list-panes` reports for a directory" (user, 2026-11-23): ScriptWire and `uniterm/api-version` stay at
  0. A held `:directory` takes a new key, or keeps its old meaning

`proposals.py check` reports these three, as expected. They wait for the user's answer.

### Implementer best guesses

- Edition coverage is equality. An approval covers a request only at the same edition. Source: M1's check "no longer
  covers it". If wrong, an older edition could cover a narrower meaning, which ADR-14 P10 allows.
- A test applet's schema stays non-zero only where the test's subject is the 1.0+ major and minor rule.
- The freeze check names a schema `command schema <applet type expression>`, and a declared-stable entry must use that
  name.
- The `.sig` format stays 1. It is not on the freeze's list. Whether it belongs there is the maintainers' call.
- UTERM-029 and UTERM-032: `input-file` loses its version and is named by kind. UTERM-063 gives a script no way to say
  which edition it needs. UTERM-029 records this as open.
- UTERM-040: no schema 2.0. A changed command takes a new name, and its old name is retired.

### Checks

- `make fmt-check lint check`: pass, including the freeze check and its self-test.
- `make test-ci`: pass.
- `xcodebuild build-for-testing`: TEST BUILD SUCCEEDED.
- `caffeinate -dimsu make test-package`: the coordinator's run at 12:06 passed 3306 tests, 10 skipped, in 284 s.
- Unowned failure: in the implementer's two full runs after the UI fixes, at about 12:00,
  `ProcessReaperTests.testTheReaperLogsThePidPathAndFailuresButNotAGoneHelper` failed. It saw no OSLog entry for the
  reaper's kill. It passed alone, in 4 earlier full runs, and in the coordinator's full run. The implementer blamed the
  concurrent UI run. That is wrong, because the UI run had ended at 11:50. The cause is unresolved. The test's code is
  untouched by this milestone, and no earlier record of it failing exists.
- First UI run, 11:41 to 11:50, 60 tests in 11 classes: 5 failures this milestone caused. Four were in
  `ControllerConsentUITests` and one in `ControllerRunUITests`. Their packages wrote descriptor formats 2 and 1, which
  the new build refuses by name. Fixed.

### Review

- adr-impact: no conflict. ADR-13 is amended in place by the user's approved text. ADR-14 P10 holds, since edition
  equality is stricter than P10 needs. The format move is recorded in the proposal, and does not need an ADR.
- The reviewer had six findings:
  - The fixture applets stayed at 1.x, on a cost-only reason the plan did not approve. Fixed the plan's way, and the
    narrowing amendment was reverted.
  - `merged` dropped stored older-edition entries, an addition the plan did not have. Removed.
  - A doc comment wrapped wrong. Fixed.
  - The As built block argued two divergence reasons. Trimmed, with a pointer to a new Decision Log entry.
  - PLAUSIBLE: the freeze check missed `AppletCommandSchema.init(`, a typealias, and a contextual `.init(`. The trace
    confirmed it from the pattern and a scratch fixture. The check now fails on all three, with self-test cases.
  - ADR-13 reference labels in other proposals still said "outside wires". Fixed.

Committed as "Reset every external version to 0 and fail the build when one moves". The peer's commits "File the bug
that a local UI test run fails in a fresh checkout" and "Log a CI sighting of the launcher Escape flake" landed inside
this row's range. They are not this row's work.

## UTERM-063 M2

### What was built

- ScriptWire refuses an unknown or retired tag, call, enumerated byte, or trailing byte by name. The text says to
  rebuild the program or update uniterm. Tokens and digests read their exact size. A reply's payload and a send's
  content stay the rest of the body, and their own decoders read them strictly.
- Each exec message has a known key set, and any other key is refused by name. Both forms of an error's text still
  read.
- Each hello reads its version first, on both wires and in both directions. A hello at another version gets text that
  names both versions and never says to relaunch.
- Each wire has an empty retired-names table. The tests prove the mechanism with a table of their own.
- The bundled command and the REPL send their code directory hash right after the hello. The app reads its own
  command's identity once, before the listener serves any connection. A failed read is kept too, so nothing is adopted
  later. The adopt path is gone.
- A swapped command at the app's own path is refused with the relaunch text. One from another install names the
  running app's command path. Identity after a role message, or twice, is refused by name.

### Implementer best guesses

- The app tells the bundled command from a native controller by the peer's executable path, from the kernel. A peer at
  the app's own command path must present an identity. A peer elsewhere may send none. Source: ADR-13 P6 and the
  decision text, which left the mechanism open. The decision was amended in place. If wrong, a native controller run
  from the command's path would be refused.
- A swapped command copied to another path that sends no identity is admitted as a generic peer, as any native-style
  peer is. `refusal(forPeer:)` still gates controller, file, undeclared, and question sessions. The decision now says so.
- The identity is checked at the first role message, so the refusal reaches the reply path the peer waits on.
- Fail closed: a peer whose path the kernel cannot name, and that sends no identity, is refused. An app identity that
  names no command path refuses every program. The trace found both cases reachable only for an exited peer or a test
  fake.
- The public listener start takes a required command identity. Tests use a test-named start.

### Checks

- `make fmt-check lint check`: pass.
- `make fuzz`: pass, 334 s, before the review fixes. The fixes changed no decoder.
- `xcodebuild build-for-testing`: TEST BUILD SUCCEEDED.
- `caffeinate -dimsu make test-package`: the coordinator's run at 12:52 passed 3337 tests, 10 skipped, in 291 s. The
  implementer's last run after the fixes passed in 290 s.
- Unowned failure, continued: `ProcessReaperTests.testTheReaperLogsThePidPathAndFailuresButNotAGoneHelper` failed in
  the implementer's two full runs at 12:38 and 12:45, with the same missing OSLog entry. It passed alone, in a partial
  run, in both of the coordinator's full runs, and in the implementer's last full run, with nothing else running. Its
  code is untouched. The cause is unresolved. The failures came only in runs where the implementer had other work going.
- UI run at 13:05, 67 tests in 13 classes that drive the bundled command, the REPL, questions, exec drivers, and
  controllers: 4 failures. They were `ControllerConsentUITests.testControllersAndPermissionsShowsAndRevokesTheApproval`
  ("a revoked approval still covered a run"), `ControllerConsentUITests.testThePanelAllowsOnceAndDeniesAReview` ("the
  terminal did not take the keys"), `PendingRequestsUITests.testAnOutsideProgramAsksAndAGrantLetsItsNextCallThrough`
  ("the Pending Requests panel never opened"), and
  `QuestionsUITests.testReturnPressesPrimaryOutsideAMultilineFieldAndInsertsANewlineInside` (the field read nil).
  - All four passed together, run alone, at 13:14.
  - The whole 13-class selection then passed 67 of 67, in the same order, at 13:15.
  - The two `ControllerConsentUITests` failures match the flaky entry "`ControllerConsentUITests`, several tests,
    after the strict and unsafe modes landed", which names both tests failing together in a multi-class run. The other
    two have no entry.
  - A passing rerun does not prove they are flakes. The cause of each is unresolved. The revoked-approval message
    deserves a look, since a revoke that does not take would be a trust bug.
- An incremental SwiftPM build did not recompile code that depends on `WireError` after a case was added. Image tests
  then failed on wrong enum values. The implementer touched the 40 files that name it, and a fresh build is fine.

### Review

- adr-impact: no conflict. ADR-13 P6 covers the bundled command's identity, and ADR-14 P9 holds, since the presented
  hash only refuses and never grants. No decision clears the ADR bar.
- The reviewer had four findings, and one hardening note:
  - CONFIRMED: a failed launch read was not kept, so a command that appeared later was adopted. Fixed. Its regression
    test failed on the old code first.
  - PLAUSIBLE: a peer whose path could not be read was admitted without an identity. Traced, and fixed to fail closed,
    along with adr-impact's matching note on a missing command path.
  - A doubled doc comment line. Fixed.
  - The decision did not state what a copied command at another path gets. Fixed.
  - Hardening: the listener's command identity was optional on its public start. Now required.
