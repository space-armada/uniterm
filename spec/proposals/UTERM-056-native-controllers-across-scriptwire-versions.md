# UTERM-056: Native Controllers Across ScriptWire Versions

**Status:** deferred
**Created:** 2026-11-23
**Updated:** 2026-11-27
**Revisit:** when uniterm's maintainers declare ScriptWire stable, redesign the version agreement, the per-version
replies, and the floor for version 1, and decide whether a refused native controller is named

## Dependencies

- UTERM-004, for controller packages and their `native` entry kind
- UTERM-021, for the adoption of every connection a native entry opens after `uniterm controller run` execs it
- UTERM-063: ScriptWire stays at version 0 until uniterm's maintainers declare it version 1. At 0 there is nothing
  to negotiate, and a stale native controller is refused by name. This proposal is deferred until that declaration.
  Everything below describes what happens after it. Until then ScriptWire changes land in place, and nothing here
  applies. UTERM-063 M2 carries the refusal advice from M3

## Impacts

- UTERM-054 — "Version skew" and the risk "A native controller stops connecting after the capture calls ship". Both
  accept the refusal until this proposal settles what a native controller's wire is.
- UTERM-019 — "Result encoding", whose skew line says app and helper ship in one bundle and a mismatch is refused at
  the hello. That holds for the helper and not for a native controller. After the declaration, its byte value is a
  failure on a connection at the declared version, per "A value an older version cannot express".
- UTERM-050 — "What `list-panes` reports for a directory". It lands in place while ScriptWire is at 0, so a program
  declared at version 1 reads whatever the declaration froze. Nothing in UTERM-050 waits on this proposal.
- UTERM-029, UTERM-033, and UTERM-034 — checks that a mismatched command is refused at the hello. An older command is
  now refused at its begin.
- UTERM-026, UTERM-032, UTERM-047, and UTERM-048 — skew lines that said ScriptWire matches exactly, now updated.
- UTERM-004 — the hello that refuses every other version: superseded in part.
- UTERM-024 — "Version skew", whose exact-match rule holds for the command and no longer for other programs after the
  declaration. Its event and read are in the subset. Its line that an event gains fields only by adding them no longer
  holds within one declared version.
- UTERM-022 — the form result's and the form spec's rules that new keys are additive. After the declaration, an added
  key on the wire is a new version.
- UTERM-021 — its promise that a program other than the command may open an undeclared session. After a version change
  such a program is refused at that begin until it is rebuilt, as is one that sends an open begin.
- UTERM-057 — its controller begin is a command message, which stays exact match, per "What a native controller's wire
  is".

## ADR Deviations

None. ADR-13's ScriptWire line needs an amendment instead, per "What a native controller's wire is".

## Summary

Decide what happens to a native controller when ScriptWire's version changes after uniterm's maintainers declare it
version 1. ScriptWire is at 0 now, and every change lands in place. A native controller built before a change is refused
by name and must be rebuilt, per UTERM-063. That is acceptable while only the user's own controllers exist. It is not
acceptable once ScriptWire is declared stable. This proposal waits for that declaration. Amended 2026-11-27; see Decision Log.

## Motivation

A controller package whose entry is `native` runs its own signed executable. `uniterm controller run` execs it, and the
executable opens its own ScriptWire connections to the app. `ScriptControllers.adoptNativeRun` adopts them. The
executable carries its own copy of the wire, built when the controller was built.

ScriptWire's hello accepts only the app's exact version. `ScriptProtocol.validateHello` refuses any other version, in
both directions. That is fine at version 0. After the declaration, an app update that changes ScriptWire would refuse
every native controller built against the earlier version. A native controller built against a newer version would be
refused by an older app.

The refusal text must then tell the user a remedy that works. A relaunch cannot fix a native controller, since the
controller's executable is not part of the app bundle. UTERM-063 M2 already words the refusal as "rebuild or update".

ADR-13 lets ScriptWire refuse every version but its own because its two sides always ship together. A native controller
is a ScriptWire side that ships outside the bundle, so that premise does not hold for it. ADR-13 also says a wire
between uniterm and a separately deployed program keeps working when either side is older.

Several queued proposals change ScriptWire, UTERM-019 and UTERM-054 among them. While ScriptWire is at 0, each lands in
place. After the declaration, each would break every deployed native controller as it lands unless this proposal's
design holds.

Filed from bug
[20261122-native-controller-refused-after-scriptwire-change](../bugs/20261122-native-controller-refused-after-scriptwire-change.md).
The trace was confirmed against the tree on 2026-11-23, when ScriptWire carried a version number that every change
bumped. UTERM-063 has since frozen that number at 0. No native controller was built and run.

## Design Decisions (Settled)

### What a native controller's wire is

Original question: whether a native controller's ScriptWire connection is an outside wire, a bundled one, or not offered
at all.

Decision: an outside wire under ADR-13, on a subset of ScriptWire, from the declaration on. After ScriptWire is declared
version 1, the app accepts older declared versions of the messages a program that is not uniterm's own command uses, and
the bundled command keeps exact match. (addition)

- The subset is what such a program sends and receives: the hello, `begin`, requests with their values, and replies.
- The command's own messages keep exact match: the controller, file, undeclared, open, and question begins, the REPL
  attach, and the app's answers to them. An older command that sends one gets an explicit refusal, never admission. The
  refusal carries the relaunch text, and the app posts the same text, whatever process sent it. It must not pass as an
  ordinary program, since that would skip the strict-mode refusal.
- Each accepted declared version keeps one fixed meaning, and the app writes each reply for the connection's version.
- The meaning covers what is inside a reply, such as the fields of a listed pane. A change to what a field means is a
  new ScriptWire version, and the app writes the old meaning for older connections. An added reply field is a new version
  too, and older connections do not get it. The version alone then says what a program is offered. (addition)
- A floor names the oldest declared version accepted. Moving it up needs its own proposal, per ADR-13.
- Other programs on the socket get the same compatibility as a native controller.
- A remembered approval's meaning does not depend on the ScriptWire version, per ADR-14.

Rationale: ADR-13 covers any separately deployed program, and a native controller is one. One version number covered two
contracts, the bundled command's and the outside program's. Splitting them keeps the first simple and the second
stable. Withdrawing native entries, relaxing ADR-13 for them, and starting the rule only at a published wire were
offered, and the user kept the rule.

### The version floor

Original question: which ScriptWire version is the oldest the app accepts from a program that is not its own command.
The first draft named a pre-reset number. UTERM-063 removed those numbers, so the floor is redesigned at the
declaration.

Decision: the floor is version 1, the first declared version. Amended 2026-11-27; see Decision Log. (autonomous)

- No version below 1 is ever accepted. A program built at 0 is refused by name, as UTERM-063 says.
- The floor is the number 1, not "the current version", since another declared version may land first.
- Version 1's subset includes the three form calls and the `ended` failure kind. Declaring it changes no message.
- ADR-13's amendment states the floor.

Rationale: 1 is the first wire that promises compatibility, so the app carries no extra forms. A lower floor has no
meaning, and raising it later needs a proposal. Converged in 1 pass.

### How the hello agrees on a version

Original question: how the two sides agree on a version. The client speaks first, with a hello of one version number,
and checks the app's hello for its own version.

Decision: after the declaration, the app answers with the lower of the two versions, and both sides then use it.
(autonomous)

- The hello's shape is unchanged. A client at or below the app's version sees its own number back.
- A newer client reads the app's number. It continues if it speaks that version, and closes otherwise.
- A hello below the floor gets the app's own version and is refused.
- The bundled command compares the answer with its own version and prints the relaunch text.
- Skew with an app declared before this proposal ships: it refuses a newer client, which reconnects at the version the
  refusal carries. The app posts one warning per such connection. This cannot be fixed from the client's side.

Rationale: one exchange agrees on a version without a second hello or a retry. A version list in the app's hello would
break every existing client, which requires a one-number body. An environment variable from `uniterm controller run`
would serve only programs it starts, and goes stale if the app is replaced. Converged in 2 passes.

### A value an older version cannot express

Original question: what the app does when a reply, a failure kind, or an event for an older declared version holds
something that version has no form for.

Decision: after the declaration, the encoder refuses to write it, and the caller gets the failure the host already
gives for a reply it cannot send. (autonomous)

- The failure is `replyLost` after a command ran and `failed` for a plain answer. Its text names the version needed and
  says a retry at this version cannot succeed.
- A call newer than the connection's version closes the connection, as an app at that version does.
- A later proposal that adds a failure kind names the existing kind it is written as for older versions, with the same
  meaning of whether the call ran. A new kind of event reaches a program only through a call new in its version.
- Left undone: a caller may start work whose result it cannot then read at its version. It is told the work ran.

Rationale: one point of enforcement, and honest under ADR-11. Refusing a command before its effect would put a
ScriptWire version in the applet command schema, whose version ADR-13 says keeps its own rule, and the one command that
needs it has no effect. Dropping or converting a value loses data with no signal. Closing the connection drops calls
already in flight. Converged in 2 passes.

### What the user sees on a refused native controller

Original question: after the declaration the app still refuses some programs: one below the floor, an old command that
sends its own messages, and a newer program that cannot speak the app's version and closes. What the error names, what it tells the user to do,
and whether the app reports the program that closes.

Decision: the app gives each refused program the remedy that can work for it, and reports a newer program that closes
early.

- For a hello below the floor or above the app's version, the app learns who the peer is before it answers: its start
  time, its running code's hash and path, and whether it is the bundle's command. A refusal then does not race the
  peer's exit.
- The bundled command keeps the relaunch text, also when it is a newer command that a running older app meets.
- A native controller is named by the launch it matches, by the checks that adopt its run. A name is never taken by
  process ID alone. The text says it was built for an older or newer uniterm, and to update the controller or uniterm.
- Any other program reads as "A program", with "Update that program" or "Update uniterm".
- An unreadable identity gets a neutral text that names both versions and both remedies.
- A newer program that closes before it declares a role is reported once, by the same rule. A connection that declared
  a role is never reported.

Rationale: a relaunch cannot fix a native controller, and no refusal is silent. Reporting by one neutral text was
offered, with and without early closers. Option text that claimed the same check as adoption had no connection to check,
since the refusal comes before one exists. The user chose this one when asked about the special cases it needs.

## Design Decisions (Open)

None.

## Risks

- **A ScriptWire change lands after the declaration and before this ships** — likelihood: low, impact: medium. Once
  ScriptWire is declared, a change needs a new version, and a native controller at the old one is refused until this
  ships. Mitigation: the declaration waits on this proposal's design, so the cost is in front of the user when they
  declare.
- **The floor and each accepted version are a published contract** — likelihood: high, impact: medium. This is a one-way
  door, since dropping a version breaks programs and needs its own proposal. Mitigation: the floor is a fixed number, 1,
  with no older form to carry, and each version's subset is fixed by recorded fixtures.
- **A message or reply changes meaning with no version change** — likelihood: medium, impact: high. A program at a
  declared version would then read a new meaning. Recorded frames miss a change above the codec. Mitigation: recorded
  replies made by the host itself, for each accepted version, fail when a field's meaning changes.
- **Every later proposal that changes or adds a reply field carries the old form** — likelihood: high, impact: medium.
  Accepted: the user kept this promise, and the cost is spread across later proposals.
- **An older command passes as an ordinary program** — likelihood: medium, impact: high. It would skip the strict-mode
  refusal. Mitigation: below the current version the command's own messages are refused before their bodies are decoded,
  and a check covers each.
- **An in-flight proposal in Impacts changes shape before this lands** — likelihood: medium, impact: medium. UTERM-019,
  UTERM-024, UTERM-050, and UTERM-054 are accepted and not built. Mitigation: each is listed in Impacts with the section
  it must update, and M2 records version 1 behavior at the declaration.
- **A program that speaks a newer version starts work it cannot read the result of** — likelihood: low, impact: low.
  Accepted: the call says the work ran, and its text names the version to update to.

## Milestones

### M1: Agree on a version, and keep the command at exact match

**Status:** NOT STARTED

- A program at version 1 runs `begin`, requests, and replies against a newer declared app, and a newer program runs
  against an older one that this milestone built
- A hello below 1 is refused with the app's own version, and posts one warning
- Below the current version, each command-only frame with a version 1 body is refused before its body is decoded, in
  a form a version 1 peer can read, and starts no run
- An older `uniterm command` at an older hello never reaches strict mode's admission
- A second hello stays a violation
- A frame of any kind newer than the connection's version closes the connection, as does a call code, an enum member,
  or a request form above it
- A newer program continues at the app's version through a check of its own, since the command's hello check is exact
- The refusal of an old command's frame carries the relaunch text, and the app posts it once
- A form spec key first accepted at a later version is refused at version 1, as a version 1 app refuses it
- Nothing lands that lets an old connection in before replies are written for its version, so M1 and M2 ship together

### M2: Write replies for the connection's version

**Status:** NOT STARTED

- A reply, failure kind, or event that the connection's version lacks reaches no version 1 client in any call path,
  including the form calls and the second connection of one native run
- A reply that cannot be written is `replyLost` after a command ran and `failed` for a plain answer, and its text names
  the version needed and says a retry cannot succeed
- A new failure kind with no older form fails the build until the encoder names one
- Any call whose effect ran answers `replyLost` when its reply cannot be written, pane and tab opening included
- Host replies recorded at each accepted version keep exactly their recorded fields, each with its value and meaning, so
  a changed or added field fails
- A reply that gains a field at a later version is still written at version 1, without that field
- The version 1 replies are recorded from version 1 behavior, and any older form that a change landing first needs is
  carried here

### M3: Say the right thing on a refusal

**Status:** NOT STARTED

The advice for a hello at another version moved to UTERM-063 M2 on 2026-11-26. Naming the refused controller
waits on ScriptWire's declaration with the rest of this proposal. A program built at 0 is refused by name, with the
rebuild text, whatever else is built here.

- A native controller below the floor is named, and the text tells the user to update it
- A native controller above the app's version that cannot speak it is named, and the text tells the user to update
  uniterm, with one report per connection
- The bundled command, a newer command against an older app included, always reads the relaunch text
- A process that borrows a launch's ID gets no name, and a controller's descriptor name is bounded and cannot forge
  uniterm's text
- A program that exits right after the hello is still named, or gets the neutral text, since the launch is matched from
  facts captured before the answer
- The bundle's command is recognized after it is replaced on disk, by the full check and not the cached one
- A program that closes after the hello for a reason other than its version gets text worded as possible, not certain

### M4: Document the subset and record its fixtures

**Status:** NOT STARTED

- The version 1 subset has a written reference outside the Swift source, and states the rule for each later version
- The reference says an applet command's reply contents, events included, follow the command schema version, per
  ADR-13, so the rule for new event kinds does not cover them
- Recorded version 1 frames for the subset decode and encode unchanged, and fail when one changes
- A native fixture built only from the recorded frames, not the live `ScriptWire` target, runs against the current app
- ADR-13's amendment is approved by the user, and covers reply contents and added fields, the ScriptWire line, and the
  floor named for each wire
- The code agrees with the amended text

## Decision Log

- 2026-11-23: Filed as a draft from bug `20261122-native-controller-refused-after-scriptwire-change`. The user asked
  for a proposal at its triage. The bug's three fix options became candidates under "What a native controller's wire
  is". "No rule" was added as the plain behavior. The version agreement and the refusal text became follow-up questions.
- 2026-11-23: Review start: 0 milestones, 0 settled decisions, 2 risks, no live-after lines, no out-of-scope statements;
  the user asked to review the whole draft. The baseline is the commit "Draft UTERM-056 for native controllers across
  ScriptWire versions".
- 2026-11-23: (addition) The growth question. The requirement was ADR-13's rule for native controllers. The special
  cases were two version rules on one wire, an explicit refusal for an old command, replies written per version, and a
  version floor. The user kept the rule and those cases. That settles "What a native controller's wire is", narrows
  ADR-13's ScriptWire line to the bundled command, and brings in a documented wire with fixtures and the same
  compatibility for other programs on the socket. The floor and the older-version value became open questions.
- 2026-11-23: (autonomous) The version floor is 14.
- 2026-11-23: (autonomous) The app answers with the lower of the two versions.
- 2026-11-23: (autonomous, addition) A value an older version cannot express becomes a failure of that one call, through the
  encoder. It puts a rule on later proposals that add a failure kind.
- 2026-11-23: The growth question for the refusal text. The requirement was that every refused program gets a remedy that
  can work. The special cases were the bundled command, a native controller named by its package, any other program,
  and a newer program that closes early. The user chose the right remedy for each, which settles "What the user sees on
  a refused native controller".
- 2026-11-23: (addition) The growth question for reply contents, raised by the whole-proposal check. The requirement was
  ADR-13's fixed meaning. The special case was an old form written for every field whose meaning changes. Promising only
  message layout, and fields that grow but never change, were the other choices. The user chose to cover reply contents.
- 2026-11-23: (autonomous) Coherence fixes. The floor is 14 whatever lands first, and a risk that said otherwise was
  rewritten. A field may be added at any version, replacing a line that dropped fields silently. An older command's
  refusal at its begin has the relaunch text. Impacts gained the proposals whose skew lines go stale. Two refusal
  decisions reached earlier in this review are unchanged.
- 2026-11-23: (autonomous) Re-check converged in 2 passes. Risk review: added the in-flight proposals risk. No risk is
  high likelihood and high impact.
- 2026-11-23: Review gate: kept the failure-kind rule on later proposals. The user approved the ADR-13 amendment's
  direction and text as shown, and it is written into ADR-13 for them to check.
- 2026-11-23: (addition) An added reply field is a new version. It replaces a line of this review's own that let a field be
  added at any version. The user said "I want the most correct option". The three options offered first left this one
  out. ADR-13's Alternatives reject a version whose meaning grows, and a program could not tell from the version whether
  an added field is offered. ADR-13 P1 carries the rule, and so it reaches the exec wire too.
- 2026-11-23: (autonomous) Scoped ADR-13 P5 and P6 by message, not by sender, to match "What a native controller's wire
  is". The proposal loop's third pass found the mismatch. This fix was not re-checked, since three passes are its limit.
- 2026-11-23: The user checked ADR-13's amended text, kept it, and accepted this proposal. No decision earns an ADR of its
  own, since each applies ADR-13.
- 2026-11-23: (autonomous) Corrected the ADR citation for remembered approvals from ADR-09 to ADR-14, which supersedes it.
- 2026-11-24: Scheduled as M1-M4 in queue.md.
- 2026-11-26: Waits on ScriptWire's declaration, per UTERM-063. Added UTERM-063 to Dependencies. The version 14
  floor and fixtures are redesigned at the declaration.
- 2026-11-26: Deferred until ScriptWire is declared stable, per UTERM-063. At version 0 there is no version to agree
  on, and every milestone names version 14, which the reset retires. The one piece needed at 0, refusal advice that can
  work, moved to UTERM-063 M2. The user chose this. Removed queue row: `UTERM-056 M1-M4`, depends on None, note "Placed
  before every row that changes ScriptWire, so none of them refuses a native controller built at version 14. M1 and M2
  ship together". Milestones stay NOT STARTED.
- 2026-11-27: Brought in line with UTERM-063 at the user's direction. The text now describes only what happens after
  ScriptWire is declared version 1. It said before: "Today any change refuses every native controller built against
  another version" and "The floor is the number 14". The floor decision said "Decision: version 14. (autonomous)", with
  versions 8 to 13 refused. It now names version 1 as the floor. The Impacts lines for UTERM-019 and UTERM-050 said a
  changed `:directory` "is a new ScriptWire version, and a version 14 connection keeps today's rule". They now say it
  lands in place at 0. The risks, M1, M2, and M4 name version 1 where they named 14. M3 says a program built at 0 is
  refused by name.

## References

- [ADR-13](../adr/ADR-13-outside-wires-stay-compatible-across-versions.md): external wires stay compatible across
  versions, and ScriptWire's exact-match line
- [UTERM-028](UTERM-028-exec-driver-commands.md): "Version skew", the exec wire's version offer
- [UTERM-024](UTERM-024-controller-input-channel.md): "Version skew", ScriptWire's exact-match rule
- Bug [20261122-native-controller-refused-after-scriptwire-change](../bugs/20261122-native-controller-refused-after-scriptwire-change.md)
