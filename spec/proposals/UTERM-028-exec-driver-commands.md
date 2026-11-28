# UTERM-028: Exec Driver Commands

**Status:** accepted
**Created:** 2026-11-15
**Updated:** 2026-11-26

## Dependencies

- UTERM-024, for controller commands, keys, and events
- UTERM-004, for exec drivers, their launch approval, and the exec wire
- UTERM-013, for key ownership
- UTERM-063: the exec wire is at version 0. The command frames land in place after UTERM-063 M2, whose strict
  decoders refuse an unknown frame by name. There is no version offer

## Impacts

- UTERM-004 — "Exec wire format": the exec wire gains the command frames, in place at protocol version 0 under
  UTERM-063. UTERM-004 is implemented, so its text stays, and it gains a "Superseded in
  part by UTERM-028" marker when this proposal is accepted.
- UTERM-004 — "How control is enabled": Revoke Controller is offered on the anchor of a driver that holds the command
  grant, even when the driver owns no group. That section also gains a "Superseded in part by UTERM-028" marker when
  this proposal is accepted.
- UTERM-024 — "Which panes take a controller's keys" and "When commands are live": a driver's own anchor takes its
  keys and lists its rows even when disconnected. UTERM-024 is accepted and not built. Its text gains a pointer here
  when this proposal is accepted.
- UTERM-024 — "Where a controller lives": at a pane that is both one controller's member and a driver's anchor, both
  controllers' rows are listed, and keys go to the driver alone. It gains a pointer here when this proposal is accepted.
- UTERM-004 — "How control is enabled", "Exec wire format", and its Decision Log entry of 2026-11-11: a driver whose
  anchor is disconnected keeps commanding the members it already owns, as a script source does. This reverses that
  entry's rule that member commands need the driver's own pane remote-controlled. That entry gains a "superseded in
  part by UTERM-028" Decision Log line when this proposal is accepted.

- UTERM-055 — its capture frames land in place beside the command frames, at version 0. It reuses this proposal's
  per-run grant, and its drop of queued frames on revocation.

## Summary

Lets an exec driver declare commands and receive their invocations, as UTERM-024 lets a Janet controller. It is not
required by the presentation controller, which is a Janet controller.

## Motivation

An exec driver is a controller in any language. A driver that wants named user actions, such as Rerun or Step, has the
same gap a Janet controller has. Today a driver hears only its own pane's applet events.

## Design Decisions (Settled)

### The same commands and limits

Decision: a driver's commands follow UTERM-024's rules: the same keys, the same opt-in rule for panes,
the same key ownership, and the same cleanup when the driver ends. The decisions below narrow these rules for a
driver's own pane and for a pane two controllers share.

### How a driver gets the power

Original question: drivers have no `declare-permissions`. Their launch approval binds the argv, directory, and
environment. How a driver obtains the command power, or is refused it, and what label the palette shows for it, since a
driver has no verified title.

Decision: a per-run grant the user gives in the Pending Requests panel, as for a driver's clipboard powers. The palette
row names the driver with the text pane chrome shows for it, which uniterm draws. (autonomous)

- After the hello, the driver sends one declaration that lists its commands and their keys. It comes before any
  invocation. A second declaration that reaches the panel in the same run is refused. See "The command frames".
- Nothing goes live until the user chooses Allow for This Run. The panel row lists every command and key, bounded with
  a count of the rest. It names keys, not panes. It offers no Allow Once, since a declaration is not one effect. Deny
  holds for the rest of the run.
- The grant lives on the run's attachment and ends with the run. Nothing is remembered across runs, since a driver has
  no verified identity, so each run asks again.
- UTERM-024's bounds on commands and keys, its key spelling, and its refusal of a repeated command name apply.
- The launch approval never grants the power, and neither does a controller's host-launch grant that covered the
  launch.
- The palette row keeps the "Controller" kind word and names the driver as pane chrome does: the executable's name
  marked as a driver, with its PID. Chrome gains the PID for drivers, so the row and chrome show the same text. The
  driver supplies no title.

Rationale: an explicit grant per run, bound to the live requester, is what ADR-09 asks for a separate power. It covers
every launch path, including a user's Run and a restored pane's Run. Putting commands in the exec declaration would
save keys with a layout, against UTERM-024 "Powers and lifecycle" and UTERM-004 "Saved layouts". It would also take
keys with no review when a controller's host-launch grant starts the launch. Inheriting a controller's approval would
hand one requester's grant to another process with its own binding, and nothing links a driver to the run that covered
its launch. A driver-supplied title would show a claimed name without its PID, which UTERM-024's label rule forbids.
Converged in 1 pass.

### How invocations reach the driver

Original question: drivers already read stdin for events and out-of-order replies, so neither option adds a read
loop. Pushed, where a stalled driver fills the 4 MiB queue and is ended, or the same cursor read as Janet, where a
stalled driver loses only the oldest events, with a count.

Decision: pushed. The app sends an invocation message on stdin, as it sends applet events. (autonomous)

- An invocation carries UTERM-024's event fields: the command's name, the node ID of the pane whose content had focus,
  and the input, the palette or the key.
- Authority is checked again when the invocation is pushed.
- Run end and revocation stop the pushing at once. Invocation frames still in the app's outbound queue are dropped
  then, as UTERM-024 discards buffered events. Only a frame already written to the pipe can reach the driver. It is
  input the user gave before the revocation, and any effect it leads to beyond the driver's own pane is refused at the
  boundary.

Rationale: push is the exec wire's own delivery model. Applet events already push through the same 4 MiB queue, so a
stalled driver is already ended by them, and invocations add no new failure. They come at human speed and are small.
A cursor read would make every driver author build a long poll beside the push loop, and would need a cap on pending
reads per driver that the channel lacks today. UTERM-019 "Page events" rejected push for remote script callers, which
had no push stream. It left UTERM-004's pushed driver events standing. A threshold that drops only invocations would
drop them while events keep flowing, and the driver is ended at 4 MiB anyway. Converged in 1 pass.

### Version skew

Original question: exec drivers are separately deployed programs, and the app accepts only its exact protocol version
today. A plain bump refuses every deployed driver, including ones that never declare a command. The app accepting both
versions, or a plain bump.

Decision: the command frames land in place at exec protocol version 0, under UTERM-063. There is no version offer.
The user chose this on 2026-11-26. Amended 2026-11-26; see Decision Log.

- The app's hello is unchanged. UTERM-063 resets the exec wire to 0, so version 4 and the planned version 5 are gone.
- Old driver, new app: a driver that never declares commands runs as before. The app sends it no command frame, since
  the `commands` frame and invocations follow only a declaration.
- New driver, old app: an app built before this proposal refuses `declare-commands` by name, under UTERM-063 M2's
  strict decoder, before any effect.
- Every frame this proposal adds is a new message type. No existing name changes meaning, so UTERM-063's rule that a
  changed meaning is refused needs no retired name here.
- The frames carry a compatibility promise only once uniterm's maintainers declare the exec wire stable.

Rationale: at version 0 a change lands in place, and there is nothing to negotiate. The offer existed to keep deployed
version-4 drivers running, and UTERM-063 refuses every driver built before the reset anyway. The earlier decision, an
offer of versions 4 and 5, is in the Decision Log.

### Which panes are the driver's

Original question: UTERM-024 makes commands live in the controller's groups. A driver's own pane is its anchor, not a
group member, so a driver that requests no layout has no live panes. Whether the anchor pane counts, and whether its
commands survive a revocation that leaves the driver its own channel.

Decision: the anchor counts, whatever its access mode, alongside the members of groups the run owns. Revocation ends
the command power everywhere, the anchor included, for the rest of the run. (autonomous, addition)

- A disconnected anchor still lists the driver's rows and takes its keys where its body opts in. This amends, for a
  driver's own anchor only, UTERM-024's rule that a pane the user disconnects keeps all its keys. The attached channel
  is the user's explicit choice, and disconnecting never severs it, per UTERM-004. ADR-09 limits remembered
  permission, and this grant is per run.
- Revoke All Controllers is offered on the anchor of any driver that holds the command grant, whether or not it owns a
  group. It is the user's stop where disconnecting no longer is one.
- Revocation ends the command power as it ends a driver's clipboard powers today. Rows and keys leave at once,
  pushing stops, and an unanswered declaration leaves the Pending Requests panel. The driver keeps its own channel,
  its applet commands and events. A new run asks again.
- No exec-capable applet has an opted-in body today, so at the anchor this means palette rows. Keys reach the driver
  in opted-in members of its groups, such as a text viewer showing Markdown.

Rationale: a driver attached to one pane, such as a test runner with Rerun, is the Motivation's case. Counting only
group members would leave it no live pane. A layout would cure that only by making the anchor remote-controlled, which
admits every ambient caller in scope, a different power. Counting the anchor only while it is remote-controlled has the
same cost, since panes start disconnected. Keeping commands at the anchor after a revocation would leave live keys under
the badge where the user chose Revoke, against UTERM-024 "Powers and lifecycle". Asking again within the run would
contradict the one-declaration rule. Converged in 1 pass.

### Members while the anchor is disconnected

Original question, added by the whole-proposal review: a driver acts beyond its own pane only while that pane is
remote-controlled. The anchor counts whatever its mode, so a member's key could be taken while the driver cannot act on
that member. Whether a driver's commands stay live in its members while its anchor is disconnected.

Decision: a driver whose anchor is disconnected keeps the groups it already owns, as a script source does. It may still
command their remote-controlled members, so its commands stay live there. A layout still needs a remote-controlled
anchor. (autonomous, addition)

- This holds for every driver, whether or not it declares commands. It is authority policy, not wire meaning, so a
  driver's member command that was refused now succeeds. Two authority rules for one kind of program would be worse.
- Revoke All Controllers at the anchor still ends the driver's member commands and its own command power.
- The refusal for a layout from a disconnected anchor keeps saying to enable remote control. A member command no longer
  gets it.

This reverses UTERM-004's Decision Log entry of 2026-11-11, a work-queue best guess. It said a driver's member commands
need its own pane remote-controlled, "since the user's enable is what lets a program in a pane act beyond it". The
code follows that entry.

Rationale: the user's enable has already happened by the time a driver owns members. Its layout needed a
remote-controlled anchor, and each member it commands must still be remote-controlled. Disconnecting the anchor refuses
ambient callers into that pane. Revoke is the stop for the driver's reach, as for a script. UTERM-004 "How control is
enabled" makes disconnect and revoke separate actions, and says a disconnected source may still call targets it already
owns. `disconnect`'s own doc says a pane's outbound calls to panes its controller owns are not affected, and the script
path keeps them. So UTERM-004 disagrees with itself today. See the bug "A driver whose pane is disconnected cannot
command the members it owns". Keeping member commands live only
while the anchor is remote-controlled would turn a member's keys off when the user changes another pane's mode, with
nothing in the member to say why. Keeping them live while refusing the driver's commands would swallow keys it cannot
act on. Converged in 1 pass.

### Two controllers in one pane

Original question, added by the whole-proposal review: a layout's new pane may carry an exec declaration, so one pane
can be a member of one controller's group and the anchor of a driver. UTERM-024 says no pane has two controllers'
keys. Which controller's commands are live there.

Decision: both controllers' palette rows are listed there, each naming its controller. Keys there go to the attached
driver alone. (autonomous) Amended 2026-11-20; see Decision Log.

- The driver is the more specific claim on its own anchor. The group owner's keys leave that pane while the driver holds
  the grant, so no pane has two controllers' keys.
- The driver's keys are live there as soon as the user allows its declaration. When the driver's grant ends, the group
  owner's keys come back at once. Neither waits for a focus change or a click.
- Revoke All Controllers there ends both controllers, as it ends every controller of a pane today. The badge menu names both,
  and the key indicator names the controller taking keys.

Rationale: rows never collide, since each names its controller, so removing either set gains no safety. Keeping the
group owner's commands alone would hide the driver's rows everywhere when another controller placed its pane, and the
panel's row names keys, not panes. Refusing the overlap at declaration would go stale when membership changes, and the
one declaration per run would leave the driver powerless after the other controller ends. A Revoke per controller would
change UTERM-004's implemented revoke contract with no need. Converged in 1 pass.

### The command frames

Original question, added by the whole-proposal review: the declaration and the invocation are a published contract.
Their frame names and fields, and how a driver learns whether the user granted the power.

Decision: the declaration is a request whose reply waits for the user's answer. One pushed frame tells the driver of a
revocation. (autonomous)

- Command names and keys use UTERM-024's spellings, written as JSON strings without the colon, such as `"cmd-shift-g"`.
  Titles are strings. UTERM-024's bounds apply.
- The driver sends `{"type":"declare-commands","id":n,"commands":[{"name":…,"title":…,"keys":[…]}]}`. The reply is
  success when the user allows it. It is a structured error when the user denies it, the request is withdrawn, or the
  declaration is refused.
- Only a declaration that reaches the panel uses up the run's one declaration. One refused for its bounds, a repeated
  name, a malformed list, or a full panel may be sent again, fixed.
- The success reply is written before any invocation, so nothing goes live before the driver hears it. An error means
  nothing went live.
- On revocation the app pushes `{"type":"commands","state":"ended","reason":"revoked"}`. Run end closes the channel, so
  it needs no frame.
- An invocation is `{"type":"invocation","command":…,"pane":…,"input":…}`. The input is `{"kind":"palette"}` or
  `{"kind":"key","key":…}`.

Rationale: a reply that waits for the user's answer is how a driver's clipboard and layout requests already work. A
Janet controller learns of a revocation when its pending read fails. A driver has no pending read, so without the
pushed frame it would keep showing its commands as live for the rest of the run. An immediate reply plus a pushed
outcome would split one answer across two frames. Leaving the frames to implementation would let an implementer pick a
permanent contract. Converged in 1 pass.

## Design Decisions (Open)

None.

## Risks

- **The command frames become a published contract when the exec wire is declared stable** — likelihood: high,
  impact: medium. Third-party drivers will depend on them, and a declared wire format cannot be recalled. Mitigation:
  they land at version 0, where they may change in place under UTERM-063's rules until the declaration. See "Version
  skew" and "The command frames".
- **Disconnecting a driver's pane no longer stops its commands** — likelihood: medium, impact: low. A user who learned
  that disconnecting takes a pane's keys back finds the driver's rows and keys still live at its anchor and members.
  Mitigation: Revoke All Controllers on the anchor of any driver holding the grant, and the key indicator on each pane where
  its keys are live.
- **A driver's member command that was refused now succeeds** — likelihood: low, impact: low. This reverses
  UTERM-004's 2026-11-11 rule for drivers. Accepted: the members are still remote-controlled, Revoke still stops the
  driver, and a driver gains nothing a script source does not already have. See "Members while the anchor is
  disconnected".
- **This proposal rests on UTERM-024, which is accepted but not built** — likelihood: medium, impact: medium. Its
  registry, key route, liveness rule, and label rule may change during its build, and this proposal amends two of its
  rules. Mitigation: UTERM-024 is a dependency, so its milestones land first. A UTERM-024 amendment to "When commands
  are live", "Where a controller lives", "Which panes take a controller's keys", or "Palette only, with the controller
  named" reopens the matching decision here.

## Milestones

### M1: Driver commands

**Status:** NOT STARTED

Amended 2026-11-20; see Decision Log.

- A driver's declared commands show in the palette after the user allows them, and choosing one pushes an
  invocation that carries the command, the pane, and the input
- A driver that declares no commands runs as before, and receives no command frame
- The exec protocol version stays 0, and the app's hello is unchanged
- The exec wire's documentation describes the command frames
- A second declaration in one run, after one reached the panel, is refused
- Neither the launch approval nor a controller's host-launch grant gives the command power
- A denied declaration stays denied for the run, and its panel row offers no Ask Again
- The panel row lists the declared keys, bounded with a count of the rest
- The palette row and pane chrome name the driver with the same text, with its PID
- A driver's keys go live in an opted-in body of a member of its group
- Authority is checked again at each push. Run end and revocation stop pushing, and drop invocation frames the app has
  not yet written
- A disconnected anchor whose driver's keys are live there shows that, and its menu offers Revoke All Controllers
- A driver whose anchor is disconnected commands a remote-controlled member it owns, and its keys stay live there. A
  layout from that anchor is still refused
- A pane that is a controller's member and a driver's anchor lists both controllers' rows, and its keys reach the
  driver alone. The driver's keys reach it there as soon as the user allows its declaration, with no focus change or
  click first
- A declaration refused for its bounds or a repeated name can be sent again in the same run
- The declaration's success reply reaches the driver before any invocation. A revocation pushes the `commands` frame
- Revocation and run end drop only queued invocation frames, and keep queued replies and events in order. A frame being
  written when revocation lands is neither cut short nor sent twice
- A denied or withdrawn declaration replies `refused`, one refused for bounds, a repeated name, or a malformed list
  replies `bad-argument`, and one refused for a full panel replies `busy`
- A declaration withdrawn by revocation replies with its error, and a driver that never held the grant gets no
  `commands` frame
- A waiting declaration counts toward the driver's bound on waiting requests
- A driver that declares no commands, with a disconnected anchor, commands its remote-controlled members
- At a pane that is both a member and an anchor, Revoke All Controllers ends both controllers, the badge menu names both,
  the key indicator names the driver, and the group owner's rows advertise no key that is not live there. When the
  driver's grant ends, the group owner's keys reach it there at once
- A driver with no layout lists its rows at its anchor, disconnected or not, and the anchor offers Revoke All Controllers
- Revoking ends the driver's rows and keys at once, withdraws an unanswered declaration from Pending Requests, and
  leaves its own applet commands and events working. The refusal text covers its anchor commands
- The declaration's panel row offers Allow for This Run and Deny, and no Allow Once

## Decision Log

- 2026-11-15: Split from UTERM-024, which narrowed to what the presentation controller requires.
- 2026-11-16: Review start: 1 milestone, 1 settled decision, 1 risk, no `**Live after:**` lines or row gates, 4 open
  questions. No explicit out-of-scope statement. At commit "Take the deck as an argument and keep the input channel
  general". The user asked for an autonomous review of the open questions.
- 2026-11-16 (autonomous): a driver gets the command power from a per-run grant in the Pending Requests panel, after
  one declaration per run. The palette row names it as pane chrome does, which gains the driver's PID.
- 2026-11-16 (autonomous): invocations are pushed on stdin, as applet events are. Run end and revocation stop the
  pushing, and an invocation already written is not withdrawn.
- 2026-11-16 (autonomous): the app's hello offers versions 4 and 5, and the driver answers with one. Commands are
  version 5. From version 5 on, drivers ignore unknown hello fields.
- 2026-11-16 (autonomous, addition): a driver's anchor counts for its commands whatever its access mode, which amends
  UTERM-024's disconnect rule for that anchor alone. Revoke Controller is offered on the anchor of a driver holding the
  grant. Revocation ends the command power everywhere for the rest of the run.
- 2026-11-16 (autonomous, addition): pane chrome gains the PID for every driver, including drivers that declare no
  commands, so a palette row and chrome name a driver with the same text, as UTERM-024's label rule asks.
- 2026-11-16 (autonomous): whole-proposal review fixes. Invocation frames the app has not yet written are dropped at
  revocation and run end. M1's checks now cover each settled behavior, and its vague and third-party checks are
  restated. Added three open questions: members while the anchor is disconnected, two controllers in one pane, and the
  version-5 frames.
- 2026-11-16 (autonomous, addition): a driver whose anchor is disconnected keeps commanding the members it owns, at
  every protocol version, as a script source does. Its commands stay live there. This reverses UTERM-004's 2026-11-11
  rule that a driver's member commands need its own pane remote-controlled. Re-check fixes the same day name the
  reversal in the decision, its risk, and Impacts.
- 2026-11-16 (autonomous): at a pane that is both a controller's member and a driver's anchor, both sets of rows are
  listed, and keys go to the driver alone.
- 2026-11-16 (autonomous): the version-5 frames. `declare-commands` replies when the user answers, a pushed `commands`
  frame reports a revocation, and `invocation` carries the command, the pane, and the input. Only a declaration that
  reaches the panel uses up the run's one declaration.
- 2026-11-16 (autonomous): risk review. The published-contract risk drops from high impact to medium, since the version
  offer is its mitigation. Added risks for a version-4 driver that refuses the unknown `versions` field (accepted),
  disconnect no longer stopping a driver's commands, the authority change for version-4 drivers (accepted), and the
  dependency on UTERM-024. No risk is rated high likelihood and high impact.
- 2026-11-16: Review gate: kept all. The user kept the anchor counting while disconnected with Revoke offered there,
  the disconnected driver commanding the members it owns, and the PID in pane chrome for every driver.
- 2026-11-16: ADR candidate (departs from the past): a wire between uniterm and a separately deployed program keeps
  working when either side is older. Each version keeps one fixed meaning, and an old version is dropped only under a
  proposal that names the direction that fails. Written as ADR-13.
- 2026-11-16: Accepted.
- 2026-11-18: The member half of "Members while the anchor is disconnected" landed ahead of M1, in "Let a driver whose
  pane is disconnected keep commanding the members it owns". The user chose to fix the bug it covered now. M1's check
  "A version-4 driver with a disconnected anchor commands its remote-controlled members" is met by it. So is the first
  half of "A driver whose anchor is disconnected commands a remote-controlled member it owns", and its layout refusal.
  M1 still owes the keys staying live there.
- 2026-11-20: ADR-12 was retracted. The user set that a program's operation behaves as the user's. So a driver's keys
  are live as soon as its declaration is allowed, and a program's change arms or disarms nothing. UTERM-024 amended
  "When commands are live" the same day, which the last risk says reopens the matching decision here. Every settled
  decision here was read again. Only "Two controllers in one pane" rested on ADR-12, and none moved to open:
  - "Two controllers in one pane" said the driver's keys arm at the user's next focus change into the pane or click in
    its content, per ADR-12. When the grant ended, the group owner's keys came back on the same latch. It now says the
    driver's keys are live as soon as the user allows its declaration, and the group owner's keys come back at once.
  - M1 checked that each controller's keys at such a pane arm only on the user's focus change or click. It also checked
    that the group owner's keys stay off after the grant ends until one. It now checks that both take keys at once.
  - The last risk named UTERM-024's "liveness latch". It now names its liveness rule.
  - References listed ADR-12.
- 2026-11-21: Renamed the pane-wide revoke from "Revoke Controller" to "Revoke All Controllers" in the settled
  decisions, the risk, and M1, per UTERM-042 "Palette commands: wording and target". It is the same command, with the
  same ID. The title changes once UTERM-042 M1 lands. The Impacts line on UTERM-004 keeps the shipped name.
- 2026-11-21: Scheduled as UTERM-028 M1 in queue.md.
- 2026-11-22: (autonomous, addition) From UTERM-055's review. "Version skew" says a version 5 driver ignores hello
  fields it does not know, which covers fields, not unknown values in `versions`. UTERM-055 adds a later version to the
  offer. M1 gained a check that the version-5 documentation says a driver picks a version it knows and ignores the
  others, with a fixture for it. Impacts gained a UTERM-055 line.
- 2026-11-23: Correction of fact, from bug triage. The image viewer has accepted exec drivers since 2026-11-17, and the
  map viewer since 2026-11-20. "Version skew" said "No exec-capable applet ships today, but UTERM-008 M3 may ship one
  before this lands, and the skew analysis cannot rest on that order." The risk of a version-4 driver refusing the new
  hello said "no exec-capable applet ships today and no driver documentation exists". The user kept the risk at low
  likelihood, since exec drivers became possible only days ago and no driver documentation exists. The decision itself
  is unchanged, since its analysis never depended on that order.
- 2026-11-26: Waits on the exec wire's declaration, per UTERM-063. Added UTERM-063 to Dependencies. The version
  numbers in the offer and in M1 are redesigned at the declaration.
- 2026-11-26: The command frames land in place at exec protocol version 0, per UTERM-063. The user chose this over
  waiting for the exec wire's declaration, which the entry above recorded. "Version skew" no longer offers versions 4
  and 5. "The version-5 frames" is renamed "The command frames", with the frames unchanged. Removed the risk that a
  version-4 driver refuses the unknown `versions` field, since there is no such field and UTERM-063 refuses pre-reset
  drivers. M1 lost its version offer checks and gained checks that the version stays 0 and the frames are documented.

## References

- ADR-04: uniterm owns key bindings
- ADR-07: failure isolation
- ADR-09: control authority requires authenticated identity and explicit scope
- ADR-11: deferred applet replies never hide effects
- ADR-03: restored state never runs a program
- ADR-08: UI responsiveness
- ADR-13: external wires stay compatible across versions
