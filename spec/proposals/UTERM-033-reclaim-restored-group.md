# UTERM-033: Reclaim a Restored Group

**Status:** accepted
**Created:** 2026-11-16
**Updated:** 2026-11-16

## Dependencies

- UTERM-004, for groups, saved layouts, the badge's Give Group, and layout requests
- UTERM-021, for a declared file's identity

## Impacts

- UTERM-004 — "Saved layouts": adds a second way to make the explicit grant it requires. A controller run asks to adopt
  a restored group, and the user approves. The badge's Give Group stays. The saved group gains the identity of its
  last owner, as a hint that grants nothing, so the layout envelope's version goes up.
- UTERM-004 — "How control is enabled": the Allow on an adoption request in Pending Requests becomes a second local way
  for the user to enable a pane, beside pane chrome. It enables only the adopted members' saved modes.
- UTERM-004 — M4's Give Group: while a run's adoption request waits, the members' badges hide Give Group to that run.
  Give Group also writes the group's record to the new owner's selector, or clears it.
- UTERM-025 — "Slides only, beside the terminal": a presenter that calls the adopt call before its first layout reuses
  its restored slide pane instead of opening a second one. UTERM-025 does not require it, and its example script makes
  that choice when it is written.

## Summary

Lets a controller that runs again after a relaunch take back the group its earlier run left, with the user's approval.
Its layout request then places the restored panes instead of opening new ones. This is a nice-to-have. The presenter
works without it.

## Motivation

A restored layout keeps a controller's group as placement only, with no owner, per UTERM-004 "Saved layouts". The
controller does not run, per ADR-03. When the user runs it again, it is a new connection that owns nothing. It cannot
see the restored group, command it, or close it. Its layout request opens a new group beside the old one.

For the presenter, that leaves a stale slide pane, which says its content came from a program and was not restored,
beside the live one. The user can give the group back from its badge, but the script cannot ask for that, and does not
know the group exists.

## Design Decisions (Settled)

### No signal at restore

Decision: nothing tells a controller that its group was restored. The offer comes only when the controller runs again.

Rationale: a restored layout runs no program, per ADR-03, so no controller is running to signal.

### The user approves every adoption

Decision: a run adopts a restored group only after the user approves. Adoption grants the run the restored member set
and nothing more. The user's Allow also sets each member to its saved desired mode, per "What Allow enables". Give
Group still leaves the modes for the user to enable.

Rationale: UTERM-004 and ADR-09 require an explicit grant before a new connection gains restored authority. Amended
2026-11-16; see Decision Log.

### From the group's source pane only

Decision: only a run from the restored group's source pane may ask to adopt it.

Rationale: the source pane is where the earlier run started, and UTERM-004 keeps groups anchored to it. A run elsewhere
in the window has no tie to the group.

### The group records its controller

Decision: a saved group records the identity of the controller that owns it last, per "The record follows the owner".
That is the controller that made it, until the group changes hands. A run is offered the group only when its verified
identity matches. The record is a hint. It grants nothing, and the user still approves every adoption.

- The record changes the layout envelope, so its version goes up under ADR-06. An older build keeps a newer file aside.
  A file from an older build upgrades with no records, so its groups are never offered by the call. Give Group still
  hands them over.
- The record is display and matching data only. Authority comes from the run's fresh verified binding and the user's
  approval, per ADR-09.
- The record holds the verified selector the run had, the same ones remembered approvals use under UTERM-021: the
  identity, an ID and key fingerprint, for a package or a signed file, and the version otherwise. A file's version is
  its SHA-256. An unsigned package's version is its ID and descriptor hash. Matching follows the approval rules. An
  identity matches across versions. A version matches only the same bytes.
- A record that cannot be read counts as no record. It never makes the layout unreadable.
- An unsigned file's `:id` is never recorded or matched. It is a claim, and ADR-09 says a claimed name proves nothing.

Rationale: without a record, any run from the source pane could be offered any restored group. UTERM-004 records no
reason for leaving the identity out. Its rules are that a restored layout grants no authority and that a grant binds a
current verified identity. A hint that grants nothing keeps both. Reusing the approval selectors means a group follows
its controller exactly as remembered trust does, with no second notion of identity. ADR-09 says a claimed name is no
proof of identity, which is why the hint only narrows the offer, and never stands in for verification. The user chose
to track the group. Amended 2026-11-16; see Decision Log.

### The record follows the owner

Original question, found in review: what the saved record holds when the group changes owner, by the badge's Give
Group or by adoption.

Decision: the record names the group's current owner, written in the same change as the owner, and stays as the last
owner's after that owner ends.

- An owner with no verified selector, such as an undeclared connection, clears the record.
- An owner that runs from another pane than the group's source clears the record too, since the call can never offer
  the group to it.
- Give Group to a verified run on the source pane writes that run's selector. This is how a group the call cannot
  reach becomes reachable again.
- A matching adoption leaves the record as it was, since the adopting run's selector already matches.

Rationale: the hint tracks the user's latest explicit grant. Keeping the creator's identity would offer a controller,
after a relaunch, a group the user moved away from it, including panes an unverified program opened. That would undo
"Undeclared runs". Clearing the record on every hand-over would remove the group from the call for good the first time
it went through the badge, even back to the same controller. Every way the record narrows is named, and Give Group
recovers each. Converged in one pass. This gives UTERM-004's Give Group a side effect on saved data, and rewords "the
controller that made it", which the user settled.

### How the run learns of the group

Original options:

- A call that lists the restored groups on the run's source pane.
- The layout request's reply offers adoption when an ownerless group sits on the source pane.

Decision: an explicit adopt call. A new script call asks to adopt the restored group on the run's source pane. The host
looks only for an ownerless group whose source is that pane and whose record matches the run's verified selector.

- With no match, the call replies at once that no group is waiting. It reveals nothing else.
- With a match, the host files an adoption request in Pending Requests, and the call replies when the user answers. A
  program's request never opens a dialog, as for every other approval.
- On Allow, the host checks again that the run is live and unrevoked, then adopts the group. The reply lists the
  members the group now holds, with each one's pane ID, applet kind, title, and mode.
- On Deny, the group stays ownerless, and the reply says so. The run can still lay out new panes as today.
- Each outcome replies distinctly: none waiting, cannot be adopted, allowed, denied, denied earlier, busy, and
  withdrawn. The existing refusals come first: an undeclared caller, a disconnected source pane, and a run that already
  owns a group at its source pane.
- The call needs the run's declared pane-control power, as a layout does. Each adoption is still approved on its own. Run end, revoke,
  or the group dissolving while the request waits withdraws it. Nothing is adopted then.
- The script places the adopted members with a later layout that names them by pane ID, and may open new panes in it.
- The call goes up the script wire's version, under UTERM-021 "Version skew". An older app and a newer command refuse
  each other at the hello, before any effect.

Rationale: discovery waits until the user grants the group, so no call returns pane metadata the run is not
authorized for, as UTERM-004 "What anchors trust" requires. A list call would gain nothing, since the immediate "none
waiting" already tells a matching run whether a group exists. Mapping a layout's `open` nodes onto restored members would
change what `open` means for every caller, with no signal on the wire. It would guess between members of one kind, and
make layout requests wait on the user. The badge's Give Group alone cannot help a script that lays out as it starts.
Converged in one pass. The critic ranked first a variant in which Allow also enables the members' saved modes. That
variant changes a settled decision, so it is its own question below.

### Undeclared runs

Original question: whether a bare terminal-session caller may ask. ADR-09 gives it no persistent approval, since its
identity cannot be verified.

Decision: never. A caller with no verified selector gets a refusal before any group lookup. The refusal names
`(declare-permissions ...)` as the way to make the script able to reclaim, and the badge's Give Group as the way to hand
a group over by hand. It reads the same whether or not a group exists. A group an undeclared run made records no
controller, and the call never offers it.

Rationale: the settled record decision offers a group only to a matching verified identity. An unidentified caller would
be named in the request by a claimed name, which ADR-09 says proves nothing. Offering it groups with no record would
bring back the "any run from the source pane" offer the record exists to prevent. It would also widen the offer for a
record that is damaged, against UTERM-004's rule that damage only narrows a group. Give Group still serves undeclared
callers. Converged in one pass.

### What Allow enables

Original question: adoption left each member disconnected, since "The user approves every adoption" said the saved
modes still need enabling. A later layout must place every member of the run's group. The host refuses a layout that
places a pane that is not remote-controlled. So after Allow, the run's layout failed until the user enabled every
member, and the run could no longer open fresh panes either.

Decision: Allow enables the saved modes. The request's row lists each member with its saved desired mode. Allow adopts
the group and sets each member to that mode, as one local act by the user.

- Allow sets the access mode only. A saved exec driver stays inert until the user chooses Run, per ADR-03.
- Each member is enabled the way pane chrome enables it, and only when its applet can take remote control.
- When the run is no longer live at Allow, nothing is enabled and nothing is adopted.
- A group with a member that Allow would leave disconnected is never offered, per "Partial and changed groups". So
  Allow never leaves the run unable to lay out, and every member is remote-controlled when the reply is sent.
- A member the user disconnects while the request waits fails the recheck at Allow. The request is then withdrawn, and
  nothing is adopted or enabled.

Rationale: the earlier run's own creation authority already set these modes. Allow puts the group back in that state
on a fresh, explicit consent, and the row shows what each member becomes. Programs still never enable a pane. The
user's Allow does. ADR-09's rule that remembered permission never overrides a disconnected pane is not engaged, since the
row offers no lasting choice. Keeping the old sentence left the run worse off after Allow than after Deny. A release
call would bring back the duplicate panes this proposal exists to remove. Placing disconnected members would break
UTERM-004's rules that every placed pane is remote-controlled and that no program rearranges a disconnected pane. A
switch per member left off reproduces the stuck layout, and the badge already disconnects a member afterward. Converged
in one pass. This changes a sentence the user settled.

### Partial and changed groups

Original question: what happens when the user closed some members, changed a member's applet, or several restored
groups share the source pane.

Decision: the call offers only a group the run can lay out once the user allows it. A matching ownerless group
qualifies when all of these hold:

- Its content holds only the source and its members, with no nested group and no pane the user split off.
- Every member's applet can take remote control. A member restored as a placeholder, such as one saved by a newer
  build, fails this.
- Every member is remote-controlled now, or still holds its restored intent of remote-controlled, untouched by the user.
  A member the user has disconnected fails this, since any change the user makes replaces the restored intent.

Members the user closed are simply absent. The group holds the members it still has, as for Give Group. Matching groups
on one source pane always nest, since a later run's first layout wraps the source inside the earlier group. Every outer
group then holds a nested group, so only the innermost can qualify.

- A matching group that does not qualify gets one coarse reply on the wire: a group is waiting but cannot be adopted as
  it stands. The host tells the user which pane or nested group is in the way, in its own UI, so the run learns nothing
  about panes it does not own.
- Allow checks the qualifying rules again, along with liveness. A group that stopped qualifying while the request waited
  withdraws the request, and nothing is adopted.
- When an outer matching group stays after the inner one is adopted, the row says so, so the user can close it.

Rationale: once a run owns a group at its source pane, every later layout from that pane must place that group. A
group with a foreign pane, a nested group, or a member that stays disconnected can never take one. Adopting it would
leave the run unable to lay out anything, worse off than after Deny, which "What Allow enables" exists to prevent.
Offering every group for the user to pick offers outer groups that are unlayable by construction. Refusing when several
match blocks the most common case, a run that was denied and then laid out fresh. Moving the user's panes out of the
group would rearrange panes the user placed. Converged in one pass.

### What the user sees

Original question: a sheet when the run asks, or an offer on the group's badge. How it names the group and its members.

Decision: the user answers the request in one place, its Pending Requests row. The badge shows that the request waits,
and why a group cannot be adopted.

- The row names the controller by its verified selector, as review rows do. It lists each member with its applet
  kind, title, and the mode Allow will set. It notes any outer matching group left on the source pane. It offers Allow
  and Deny only, and a denial row offers Ask Again, as for every other request.
- While the request waits, the badge of each member and of the source pane shows a line naming the run that asks. The
  line has no action. It points the user to the row and shows which panes on screen the request covers.
- While a run's request waits, the members' badges hide "Give Group to" that run. Give Group to any other connection
  stays.
- When a group cannot be adopted, its badge menu says why, naming the pane or nested group in the way. The menu works
  this out from live state each time it opens.
- When a run's call finds a restored group on its source pane whose record does not match, or that has no record, the
  group's badge says so while that run is live. The line names the record's controller, if any, and points to Give
  Group. It clears when the run ends. The run's reply stays "none waiting".

Rationale: one place to decide keeps the full member list in front of the user, which the forged-layout mitigation
relies on. A badge Allow would approve from one member's view. Give Group for the same run, picked instead of the row,
would leave every member disconnected, which "What Allow enables" exists to prevent, and leave the request with no
outcome. A sheet would open a dialog a program asked for, which no other approval does. A badge-only request would
have no home for Ask Again. A reason shown as a panel row would have no lifetime and would go stale, while the badge
rebuilds from live state. Converged in one pass. Amended 2026-11-20; see Decision Log.

### Restored groups only

Original question, found in review: a run's group also loses its owner when the run ends or is revoked within the same
launch. Whether the adopt call offers such a group to a later run in that launch.

Decision: no. The call offers only a group that came back from a saved layout and has had no owner since. A group
that lost its owner in this launch is still handed over through the badge's Give Group.

Rationale: the Summary scopes the proposal to a run after a relaunch. Offering groups released in the same launch is an
addition. A revocation is not remembered across a relaunch, so this choice rests on scope, not on protecting a revoked
run. The user still approves every adoption. Recorded so a later proposal can take it up.

## Design Decisions (Open)

None.

## Risks

- **A different controller adopts a group meant for another** — likelihood: medium, impact: medium. Mitigation: the user
  approves every adoption, and the row shows what the group holds.
- **The identity record is a layout schema change** — likelihood: high, impact: medium. A downgrade after it ships
  starts a default layout, and the copy kept aside is the only recovery, per ADR-06. Mitigation: follow ADR-06's
  versioning, and treat the record as display data that grants nothing.
- **An edited script no longer matches its group** — likelihood: high for an unsigned file, impact: low. Any edit
  changes an unsigned file's version, so the run gets "none waiting" and opens a second pane, as today. Mitigation: when
  a run's call finds a restored group on its source pane whose record does not match, the group's badge says so in the
  host's UI, and Give Group hands it over. Signing the file makes the record match across versions.
- **In-flight proposals widen what Allow turns on** — likelihood: medium, impact: medium. UTERM-024 sends the
  user's keys from opted-in remote-controlled panes, and UTERM-026 lets a controller's panes span windows. Each
  could make an Allow hand over more than the row says, or break the rule that the group sits in one window.
  Mitigation: each of those proposals states how an adopted group's members take part, before it is accepted.
- **The terminal is silent while the request waits** — likelihood: medium, impact: low. An operation approval sends
  the command no notice. Mitigation: the window's pending indicator and the members' badge line show the waiting
  request.
- **A forged layout file steers the offer** — likelihood: low, impact: medium. A program that edits the layout file
  can make a group match another controller. It can also give a member, such as a terminal, a saved remote-controlled
  mode that Allow then makes live. Mitigation: the run must still verify, the user approves every adoption, and the row
  shows each member's applet and the mode Allow will set. Accepted beyond that: ADR-09 gives no isolation from a
  malicious process of the same user, which could already drive the app in other ways.

## Milestones

### M1: Adopt a restored group

**Status:** NOT STARTED

Amended 2026-11-20; see Decision Log.

- After a relaunch, a run from the source pane asks to adopt the restored group, the user approves, and its layout
  request places the restored panes with no new pane
- A denied request leaves the group ownerless, and the run's layout opens new panes as today
- A run from another pane is never offered the group
- A run whose verified identity does not match the group's record is never offered it
- An older build keeps a layout file with the record aside, unchanged
- Each outcome of the adopt call replies distinctly, and the request's row offers Allow and Deny only, with no choice
  that lasts for the run or the session
- A denial is keyed by the group and the run's selector, so it blocks only that group's adoption, and the next
  request's reply says it was denied earlier and points to Ask Again
- Allow after the run ended or was revoked adopts nothing, and a group that dissolves while its request waits
  withdraws the request
- An undeclared caller gets the same refusal whether or not a restored group sits on its source pane
- An adopt call from a run that already owns a group at its source pane is refused and changes nothing
- An adopt call from a disconnected source pane gets the existing disconnected-source refusal before any group lookup,
  and Allow never enables the source
- A group the user split a member of, a group holding a nested group, and a group with a placeholder member each get
  the "cannot be adopted" reply, and none is adopted
- After Allow, the run's later layout that places every member succeeds with no further user step
- For an unsigned file, the row names the controller by its file version, and labels any declared name or ID as claimed
- Member titles in the row are escaped as review names are, so only host-written fields start a line
- The record is taken when the group is created, and survives the run ending before the layout is saved
- A record that cannot be read leaves the layout readable and the group never offered, and a group an exec driver made
  records nothing
- A group whose owner ended in this launch is not offered by the call
- Give Group to another connection while a request waits withdraws the request
- The members' badges hide Give Group to the waiting run, the waiting line shows on the members and the source, and the
  "cannot be adopted" reason is built from live state
- A layout request from a run whose adoption request waits is refused as busy
- Allow starts no exec driver
- A group whose record does not match the asking run, or has none, says so on its badge while that run is live, and
  the line clears when the run ends
- A run that did not declare pane-control is refused before any group lookup, and a pane-control approval the run
  still needs is answered before the adoption row is filed
- A member that stops qualifying while the request waits withdraws the request at that moment, with the reason on the
  badge
- A member closed while the request waits leaves the row's member list, and Allow adopts only the members that remain
- Give Group to a verified connection on the source pane, then a save, stores that connection's selector. Give Group to
  an undeclared connection or to one on another pane, then a save, stores no record
- An older command and a newer app refuse each other at the hello across the script wire's version change, and so do
  a newer command and an older app

## Decision Log

- 2026-11-16: Filed as a nice-to-have. The user chose it after asking whether a restored presenter duplicates panes. It
  does today: a new run opens a second group beside the restored one.
- 2026-11-16: The saved group records the controller that made it, as a hint that grants nothing. The user said the
  group needs tracking. The previous text claimed UTERM-004 saves no such record by design. UTERM-004 records no reason
  for that, and nothing in it or ADR-09 forbids a record that grants nothing.
- 2026-11-16: The record holds the run's verified selector, identity or version, matched by the approval rules. The
  user noted it had a correct answer. The previous text left it open, with a content hash or no record as options for
  a file without an `:id`.
- 2026-11-16: Review start: 1 milestone, 4 settled decisions, 3 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the four open questions. Proposal at commit
  "Record a restored group's controller by its approval selector".
- 2026-11-16 (autonomous): The run learns of its group through an explicit adopt call that files a Pending Requests
  row, and the reply lists the members only after Allow.
- 2026-11-16 (autonomous): An undeclared caller is refused before any group lookup, with a message that names
  `(declare-permissions ...)` and the badge's Give Group.
- 2026-11-16 (autonomous): Opened "What Allow enables". Adoption leaves every member disconnected, and a later layout
  refuses disconnected panes, so the settled "still need enabling" sentence keeps the adopted run from laying out.
- 2026-11-16 (autonomous): Allow enables each member's saved mode. "The user approves every adoption" said before: "The
  members' saved desired modes still need enabling, as for Give Group." It now says Allow sets them, and Give Group
  still leaves them to the user. The old sentence left an adopted run unable to lay out at all.
- 2026-11-16 (autonomous): The call offers only a group the run can lay out after Allow, which is the innermost of a
  nested chain, and rechecks that at Allow. A group that does not qualify gets one coarse "cannot be adopted" reply,
  and the user sees the reason in the host's UI.
- 2026-11-16 (autonomous): The user answers an adoption request only in its Pending Requests row. The badge shows a
  waiting line with no action, and why a group cannot be adopted.
- 2026-11-16 (autonomous, addition): While a run's adoption request waits, the members' badges hide "Give Group to"
  that run. This changes UTERM-004's Give Group, which offered every connection acting in the window.
- 2026-11-16 (autonomous): The adopt call offers only groups restored from a saved layout, not groups whose owner ended
  in the same launch. Offering those would be an addition beyond the Summary's "after a relaunch".
- 2026-11-16 (autonomous): Coherence pass. A member the user disconnects while a request waits now withdraws the
  request at Allow. The text before kept the user's choice and replied with that member disconnected, which contradicted
  the rule that Allow never leaves the run unable to lay out. "The group records its controller" now states a package's
  version selector and the old-to-new upgrade. It said "the version, the file's SHA-256, otherwise", which missed an
  unsigned package. The UTERM-025 impact is narrowed to a presenter that calls the adopt call, since UTERM-025 is a
  draft that does not require it. Added risks for downgrade loss, an edited unsigned script, in-flight proposals, and a
  silent terminal.
- 2026-11-16 (autonomous, addition): The record follows the group's owner. Give Group writes it to the new owner's
  selector, or clears it for an owner the call could never offer the group to. "The group records its controller"
  said before: "a saved group records the identity of the controller that made it." Keeping the creator would offer a
  controller a group the user moved away from it.
- 2026-11-16 (autonomous, addition): A restored group's badge says when a run on its source pane asked and its record
  did not match, while that run is live. It mitigates the risk that an edited unsigned script silently opens a second
  pane. The re-check pass converged with no design-level finding.
- 2026-11-16 (autonomous): Risk review. Every risk carries a likelihood, an impact, and a mitigation or acceptance.
  None is high likelihood and high impact. The envelope bump is the one-way door, recorded with its downgrade cost.
- 2026-11-16: Review gate: kept all. The user confirmed that Allow sets the saved modes, that the record follows the
  latest owner, that Give Group hides the waiting run, and the mismatch badge line.
- 2026-11-16: UTERM-031 is retracted, so the risk "In-flight proposals widen what Allow turns on" no longer names it.
  It said "UTERM-024 and UTERM-031 send the user's keys from opted-in remote-controlled panes".
- 2026-11-20: ADR-12 was retracted. The user set that a program's operation behaves as the user's. The rationale of
  "What the user sees" said "A sheet would open a dialog a program asked for, and take the keyboard, against ADR-12."
  It now says only that no other approval opens a dialog. The decision stands on that and on its other reasons. M1
  lost the check "The request takes no focus when it is filed, per ADR-12". No check replaces it.

## References

- ADR-03: restored state never runs a program
- ADR-06: layout file versioning
- ADR-09: control authority requires authenticated identity and explicit scope
