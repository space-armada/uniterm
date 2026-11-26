# UTERM-063: External Versions Stay at 0 Until Declared Stable

**Status:** designing
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Impacts

- ADR-13 — needs the amendment in "ADR-13 at version 0". Its P5 names version 4 for the exec wire and 14 for
  ScriptWire, which this proposal resets.
- ADR-16 — proposed. Its Consequences say a changed answer is a new version under ADR-13. While the wire is at 0, the
  change lands in place under "A changed meaning is refused, never reinterpreted".
- UTERM-028, UTERM-056 — accepted, not started. They negotiate versions on the exec wire and ScriptWire. While a wire is
  at 0 there is nothing to negotiate, so each waits on its wire's declaration. UTERM-028's offer names versions 4 and 5,
  which the reset retires, so its version numbers are redesigned at the exec wire's declaration.
- UTERM-050 — accepted. Its bump of `uniterm/api-version` does not happen. The scripting API version stays at 0, and the
  change lands in place. Its ScriptWire change lands in place too under "A changed meaning is refused, never
  reinterpreted": a held `:directory` that may be gone takes a new key, or the old meaning holds.
- UTERM-062, UTERM-064 — their commands change in place at 0. Each change follows "A changed meaning is refused, never
  reinterpreted": an older program's message is read with its old meaning or refused.
- UTERM-006, UTERM-019, UTERM-024, UTERM-026, UTERM-029, UTERM-030, UTERM-032, UTERM-040, UTERM-048, UTERM-054,
  UTERM-055, UTERM-057 — each plans a new version of an external interface. While that version is at 0, the change
  lands in place instead.
- Every impacted proposal above — an in-place change to an external interface at 0 lands only after M2, which builds
  the guards against stale programs.

## Summary

Every external version in uniterm resets to 0 and stays there through breaking changes. An external version is one that
a program or file uniterm does not build must name or check. Version 0 says the interface is not stable and makes no
compatibility promise. An older program is refused, never reinterpreted. An external version leaves 0 only when the
user declares it version 1, separately from uniterm's own release. A check fails the build when one moves without that
declaration. Internal versions, which only uniterm reads, keep their own rules.

## Motivation

The user's goals, in their words on 2026-11-26:

- Version 0 shows that the external interface is not stable, and provides no backwards-compatibility guarantee yet
- uniterm is in active development, with many breaking changes. Bumping a version is almost meaningless, because even
  early adopters may not see every version
- It is awkward for uniterm 1.0 to require ScriptWire version 14, when none of the earlier versions were really
  published or available

Today ScriptWire is at version 14, the exec wire at 4, and the viewers' command schemas at 1.0. Each number counts
breaking revisions made before anyone needed them kept. ADR-13 then promises compatibility from those numbers on, so
every later change to a wire pays for version splits and negotiation that serve no deployed program. UTERM-062 showed
the cost: requiring programs to name a tab needed a compatibility rule for programs that do not exist outside the
user's own.

## Design Decisions (Settled)

### Every external version is at 0

Decision: every external version resets to 0. A schema's version is 0.0. Every program built against an earlier build
must be rebuilt or rewritten against this one. The user chose this on 2026-11-26. Amended 2026-11-26; see Decision Log.

Rationale: version 0 means "no compatibility promise", as in semantic versioning. Resetting now, before any other
proposal bumps a version, makes one break instead of many.

### Version 0 never bumps

Decision: while an external version is at 0, a breaking change lands in place, and the version stays 0. The user chose
this on 2026-11-26, over semantic versioning's 0.y, where the minor still moves.

Rationale: a bump at 0 promises nothing, so it only adds noise and the temptation to keep old versions alive. The cost
is that a frozen number cannot tell an old program from a new one at the handshake. See "Errors name the mismatch",
"A changed meaning is refused, never reinterpreted", and "A replaced bundle is refused before any call".

### An external version reaches 1 only when the user declares it

Decision: each external version leaves 0 only when the user declares it version 1. No version moves automatically, and
none moves because a proposal changes something. Each is declared on its own, and none is tied to uniterm's own
release. From version 1 on, ADR-13 applies to a wire in full, and every other external version follows its own rule.
The user chose this on 2026-11-26.

Rationale: a protocol is ready to promise compatibility when its shape has settled, which can come before or after the
app's 1.0. The user asked that no version move again unless they say so.

### What the freeze covers

Decision: the freeze covers every external version, and only those. The user chose this on 2026-11-26.

External: a program or file that uniterm does not build names or checks the version.

- ScriptWire's protocol version. Native controllers ship on their own and speak it. The bundled `uniterm` command
  speaks it too, but one number serves both
- The exec wire's protocol version, spoken by exec drivers in any language
- Each applet's command schema version, named by scripts, exec drivers, and controllers
- `uniterm/api-version`, the Janet scripting API's version, checked by the user's scripts
- The controller descriptor format, written by controller authors
- Each controller permission's version, named in those descriptors

Internal: only uniterm reads the version. These keep their own rules, and stay out of the freeze and the check.

- DocumentWire and ImageWire. The app and its document and image helpers ship in one bundle, so they keep exact-match
  bumps
- The layout file's envelope version, and each applet's saved state inside it, under ADR-06
- The map's command-pin snapshot and the browser's HSTS store
- The controller policy file's format. uniterm writes it when the user approves a controller, and reads it back

The check reads a named list of constants: ScriptWire's and the exec wire's versions, each registered applet command
schema's version, `uniterm/api-version`, the descriptor format, and each permission's version. It never greps for the
word "version".

Rationale: the user's goals are about what outside programs see. Version 0 tells an author the interface is unstable.
Their programs would otherwise depend on numbers that count unpublished revisions. An internal version is internal in
the sense that only uniterm needs to know it. Nobody outside reads its number, so it says nothing about stability to
anyone, and its bumps cost no author anything. DocumentWire and ImageWire keep their exact match, which tells two builds
apart when the bundle is replaced under a running app.

### Errors name the mismatch

Decision: since the handshake no longer catches a stale program, each wire's decoder refuses a message it cannot read
with an error that names the field or message that did not match. It says the program must be rebuilt against this
uniterm build, or that uniterm must be updated when the program is the newer side. A message from a stale program never
acts on a guess.

Rationale: a stale program now passes the handshake and fails on the first message whose shape changed. An error that
names the field and the fix is the only signal left.

### A changed meaning is refused, never reinterpreted

Decision: while an external version is at 0, a message an older program sends is either read with its old meaning or
refused. It never acts under a new meaning. Three rules keep this:

- A change of meaning never reuses a field name, message type, tag, or enumerated value. The changed thing takes a new
  name, and the old one is retired. The meaning of an omitted key or field is part of its message's meaning. Changing
  what an omission does takes a new name too, unless the omission is now refused
- Every uniterm decoder on these wires refuses a key, field, tag, or message type it does not know, with an error that
  names it. That includes the exec wire's envelope, which ignores unknown keys today
- ScriptWire and the exec wire each keep a table of retired names. A test sends each retired name and checks that it is
  refused by name

Version skew, in both directions. The units are uniterm and each separately deployed program: exec drivers in any
language, and native controllers. An old program talking to a new uniterm is refused by name at its first message that
changed. A new uniterm talking to an old program shows the program only names it does not know, never a known name with
a new meaning. The old program's own decoder decides what to do with them. uniterm does not own that decoder, so the
program may stop working, but it never misreads. (autonomous)

Rationale: a strict decoder alone accepts a field that keeps its bytes and changes meaning. ScriptWire decodes by
position, so a value that once meant a pane and now means a tab would act on the wrong object. The exec wire ignores
unknown keys, so a renamed `pane` key would make a stale driver's command act on its own pane. A rule without a check
is forgotten, as "The build enforces the freeze" says.

### The hello's version field keeps one form

Decision: the hello field that carries each wire's protocol version keeps its name and shape in every version, the
reset included. Every peer reads that field first, and refuses on it before it reads any other hello field. The refusal
names both versions. Version 1 or later may add hello fields, as UTERM-028's offer does.

Rationale: the reset's own refusal of version-14 and version-4 programs depends on it. So does a later declared
version's refusal of a version-0 program. Fixing the whole hello would forbid the handshake extension ADR-13's
Consequences expect. ScriptWire's code already documents a one-field hello. The exec hello's schema field changed shape
once, at protocol 4, while its protocol field did not. (autonomous)

### A replaced bundle is refused before any call

Decision: the bundled `uniterm` command proves it comes from the same build as the running app. It sends its code
identity in a message right after the hello. The app compares it with the identity of the command it kept at launch,
and refuses a mismatch before any call runs. The app never adopts a command it finds on disk later as its own. A
mismatch from this bundle's own command path says to relaunch uniterm. One from another install's command names the
running app's own command path. Programs built outside the bundle, such as native controllers, send no identity and are
unaffected. (autonomous)

Rationale: replacing the bundle under a running app pairs an old app with a new command. The exact version match caught
this before, and ScriptWire's code documents the refusal. At a frozen 0 both sides say 0. Without this check the first
call may run before a later one fails, or a call that keeps its bytes runs under a new meaning. ADR-13 P6 already lets
the bundled command's messages refuse every build but their own. Today the app re-reads the command on disk and adopts
it, which would let a swapped command pass, so that path goes.

### The build enforces the freeze

Decision: a check, run by `make check` and CI, fails when any version the freeze covers differs from 0, unless that
external version is listed as declared stable. The list lives in the repository and starts empty. Only the user adds to
it, as the declaration. The project's instructions point at the check.

Rationale: an instruction alone is forgotten by the next session that bumps a version out of habit. A failing check
cannot be.

### ADR-13 at version 0

Decision: this proposal asks the user to amend ADR-13 with the following text. The amendment applies once the user
approves it. Amended 2026-11-26; see Decision Log.

> **C1** (relaxes P1, P2, P3, and P5): a wire whose protocol is at version 0 carries no compatibility promise. A change
> may land in place, without a new version, and an older program may stop working. An older program's message is still
> read with its old meaning or refused, never reinterpreted, which keeps P1's reason. Version 0 marks a wire whose shape
> has not settled, offered to no program outside the project. A contract the wire carries keeps its own rule, per P4.

> **P5** (amended): the rule holds from version 1 of each wire, which the user declares.

> Amendments line: "2026-11-26: Added C1. A wire whose shape has not settled carries no compatibility promise, since no
> outside program relies on it. C1 keeps P1's reason: an older program is refused, never reinterpreted. P5 names version
> 1, since the starting versions it named no longer exist. Removed: "The rule holds from the version named for each
> wire. For the exec wire that is 4. For ScriptWire's messages other than the bundled command's own, it is 14. Earlier
> versions were refused before the rule applied, so it does not reach them.""

Applet command schemas stay under P4's "keeps its own rule". Their rule lives in the command schema version's contract
in AppletKit. M1 rewrites that contract for version 0.0: a schema at 0.0 never bumps, and a change follows "A changed
meaning is refused, never reinterpreted". From a schema's version 1.0, the major and minor rule applies again.

Rationale: ADR-13 would otherwise require a new version for every change, which version 0 exists to avoid. C1 covers
wire protocols only. Naming schemas would put them under P1 from version 1.0, against P4, and two rules
would give two answers for one schema. Permission versions keep the rule ADR-14 P10 relies on.

## Design Decisions (Open)

### A permission whose meaning changes at 0

ADR-14 P10 says a change in a permission's meaning cannot widen an existing approval without the user's consent. Today a
changed meaning is a new permission version, and a stored approval names the old one, so it does not cover the change.
At a frozen 0 the version cannot carry that.

- Apply "A changed meaning is refused, never reinterpreted": a permission whose meaning changes takes a new kind name.
  An approval stored under the old kind never covers the new meaning, so ADR-14 P10 holds with no version moving
- Leave permission versions out of the freeze, against the user's rule that every external version freezes

### The controller policy file at the reset

The policy file stores each approval as a permission kind and version, all at 1 today. After the reset this build knows
only version 0. It reads a pre-reset file as written by a newer uniterm, then remembers no trust and saves none, and
leaves the file as it is. Every controller approval would stop being saved until the user deletes the file by hand.

- Read a pre-reset file's version-1 permissions as version 0, since the reset changes no meaning. Remembered approvals
  survive the reset
- Set a pre-reset file aside, as a broken file is today, with a notice. The user approves each controller again

## Risks

- **Programs built against an earlier build stop working** — likelihood: high, impact: low.
  Accepted: the only such programs are the user's own, and the user chose the break on 2026-11-26.
- **A stale program passes the handshake and fails later** — likelihood: high, impact: low.
  Mitigation: "A changed meaning is refused, never reinterpreted" refuses it by name at its first changed message, and
  "Errors name the mismatch" names the fix. A replaced bundle is refused at the identity check instead. Likelihood is
  high because the user's own rebuilds produce stale programs.
- **A later proposal bumps a version out of habit** — likelihood: high, impact: low.
  Mitigation: the build check fails, and names the declared-stable list.
- **Controller packages must be rewritten at the reset** — likelihood: high, impact: low. Every package's descriptor
  names format 1 or 2, and every permission names version 1. After the reset each must name 0 and be signed again.
  Accepted: the only packages are the user's own and the repository's fixtures, and M1 rewrites the fixtures.
- **A session adds to the declared-stable list to make the check pass** — likelihood: medium, impact: medium.
  Mitigation: the project's instructions say only the user adds to the list, and an addition shows in the diff the user
  reviews.
- **A program built before the reset names version 1** — likelihood: low, impact: medium. After the user declares an
  external version 1, a program or script from before the reset that still names 1 or 1.0 passes the version
  check under the new meaning. A script that checks `(uniterm/api-version)` against 1 does the same.
  Accepted: the user chose version 1, and such programs are the user's own.
- **Declaring a wire stable is a one-way door** — likelihood: medium, impact: medium. From version 1, ADR-13
  holds the wire to P1 through P3, so its next change needs the negotiation UTERM-028 or UTERM-056 builds.
  Mitigation: only the user declares, and UTERM-028 and UTERM-056 wait on that declaration, so the cost is in front of
  the user when they declare.
- **Every in-place change makes the user re-approve rebuilt native controllers** — likelihood: high, impact: low. A
  stale native controller must be rebuilt, which changes its version digest, and ADR-14 P9 ties a remembered approval
  to that digest. Accepted: the only native controllers are the user's own, and a rebuild already asks today.
- **An outside program relies on a wire at 0** — likelihood: low, impact: medium. C1 rests on no outside program
  relying on a wire at 0. Accepted: the user stated on 2026-11-26 that the only such programs are their own, and a wire
  someone else needs is declared stable first.

## Milestones

### M1: Reset to version 0 and freeze

**Status:** NOT STARTED

No external interface changes shape in this milestone, so a pre-reset program is refused at the hello, and two builds at
0
agree on every message.

- ScriptWire, the exec wire, every applet command schema, the controller descriptor format, and every controller
  permission report version 0, and a schema reports 0.0. DocumentWire and ImageWire keep their versions
- A protocol-mismatched exec hello is never admitted on its placeholder schema of 0.0
- `uniterm/api-version` reports 0, and its doc says it stays at 0 until the user declares it
- The bundled `uniterm` command, the Janet helper, every test fixture, and every example driver and controller in the
  repository speak version 0, `Tests/ExecTestSupport/Fixtures/driver.pl` and the controller package fixtures included.
  Tests that compute an older version as the current one minus 1 still work at 0
- `make check` and CI fail when any version the freeze covers differs from 0 and is not on the
  declared-stable list. The check reads the named constants, and covers every registered applet command schema,
  `uniterm/api-version`, the descriptor format, and every permission version
- The declared-stable list exists, empty, and the project's instructions name it
- The check leaves every internal version alone: DocumentWire, ImageWire, the layout and payload versions, the
  command-pin snapshot, the HSTS store, and the policy file format
- The version docs on ScriptWire, the exec wire, and the command schema version describe version 0 and 0.0
- ADR-13 carries the amendment the user approved, or the milestone waits for it
- ADR-16's consequence line says a changed answer lands in place while its wire is at 0
- UTERM-028 and UTERM-056 say each waits on its wire's declaration
- The impacted proposals that plan a version bump say the change lands in place while the wire is at 0, after M2

### M2: Refuse stale programs by name

**Status:** NOT STARTED

These guards are changes at version 0, so C1 covers them. No other in-place change lands before this milestone.

- Every uniterm decoder on ScriptWire and the exec wire refuses a key, field, tag, or message type it does not know,
  with an error that names it and says to rebuild the program or update uniterm
- ScriptWire bodies with trailing bytes are refused by name. A positional field whose meaning changes takes a new
  message tag, since the field itself has no name
- The strict exec decoder still reads both forms of the `error` message's text, `error.message` and `message`
- A pre-reset exec hello with extra keys is refused with the version text, not an unknown-key error. Each peer reads the
  hello's version field first, and a test refuses a hello from another version with both versions named
- ScriptWire and the exec wire each carry a table of retired names, empty at first. A test sends each retired name and
  checks that it is refused by name
- The bundled `uniterm` command and the REPL send their code identity right after the hello. A swapped command from
  this bundle is refused before any call with the relaunch text, and one from another install names the running app's
  command path. The identity message keeps one form
- The identity message has one fixed place relative to the REPL's `attach` and the command's `begin`, and the other
  order is refused by name. ScriptWire's doc on `attach` says where it sits
- The app reads the identity of its own command before the listener admits any connection, and never adopts a command
  it finds on disk later
- The ScriptWire library that native controllers link never sends an identity on its own. A native controller built
  against it is admitted as before. The app never sends its own identity first

## Decision Log

- 2026-11-26: Drafted from the UTERM-062 review. The user chose to reset every wire and schema to version 0, to keep
  them at 0 through breaking changes, and to declare version 1 for each wire separately from uniterm's release.
- 2026-11-26: Review start: 1 milestone, 6 settled decisions, 3 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the draft, as committed in "Draft UTERM-063 and
  UTERM-064 from the UTERM-062 review".
- 2026-11-26: The freeze covers ScriptWire's and the exec wire's protocol versions and the applet command schemas.
  DocumentWire, ImageWire, layout and payload versions, controller descriptor and permission versions, and the policy
  file keep their own rules. Converged in 1 pass. (autonomous)
- 2026-11-26: Review gate: DocumentWire and ImageWire join the freeze, since the user's rule covers every wire. The
  review had left them bumping without asking. They get the same guards as ScriptWire: strict decoders, and a check that
  each helper comes from the app's own build.
- 2026-11-26: Review gate: `uniterm/api-version` joins the freeze. The user stated the rule: a version stays at 0, with
  no automatic bump and no bump because of a proposal, and leaves 0 only when the user says so. The review had left it
  out to keep its "a change that breaks a script changes it" doc.
- 2026-11-26: An older program's message is read with its old meaning or refused, never reinterpreted: a changed
  meaning takes a new name, decoders refuse unknown names, and a retired-names table is tested. Both skew directions
  stated. Converged in 1 pass. (autonomous)
- 2026-11-26: Each wire's hello keeps the form of its version field in every version, and a peer refuses on that
  field first. First written as "the hello keeps its current form", which would have forbidden UTERM-028's offer.
  (autonomous)
- 2026-11-26: The bundled command proves its build with the code identity the app kept at launch, and the app stops
  adopting a command it finds on disk. Converged in 1 pass. (autonomous)
- 2026-11-26: The review had changed "A wire reaches version 1 only when the user declares it" so that a declaration
  took a number no earlier build used. That overrode the user's settled decision, and the user rejected it at the
  review gate. The decision stands as the user chose it: version 1. The reuse of 1 by pre-reset programs is a recorded,
  accepted risk.
- 2026-11-26: Re-scoped the freeze to external versions, at the user's direction. The user wrote out the goals now in
  Motivation, and drew the line: an external version is one a program or file uniterm does not build names, and an
  internal one is one only uniterm needs to know. The freeze gains the controller descriptor format and the permission
  versions. DocumentWire and ImageWire leave it, which reverses the earlier gate entry that froze them. The title
  changed from "Outside Wires Stay at Version 0 Until Declared Stable", since a wire is only one kind of external
  interface. "Every wire and schema is at version 0" now reads "every external version". Two open questions follow:
  how a permission's meaning changes at 0, and what the reset does to the controller policy file.
- 2026-11-26: Rewrote the drafted ADR-13 amendment. C1 had said "a wire, or a contract a wire carries, at version 0
  carries no compatibility promise. Its meaning may change in place". It now covers wire protocols only, leaves every
  carried contract to P4, and keeps P1's reason. Command schemas get their version-0 rule in their own contract in
  AppletKit. P5's rewrite gained an Amendments line that quotes the removed text. (autonomous)
- 2026-11-26: Split the milestone in two. M1 resets and freezes with no change of shape. M2 builds the guards against
  stale programs, and no other in-place change lands before it. First written with the guards first, which would have
  changed versions 4 and 14 in place before the ADR-13 amendment. (autonomous)
- 2026-11-26: No `## ADR Deviations` entry is needed. M1 waits on the ADR-13 amendment, and M2 changes only wires at 0,
  so the work never departs from ADR-13 as it stands. (autonomous)
- 2026-11-26: Risk review added five risks: a pre-reset program naming version 1, additions to the declared-stable list,
  declaration as a one-way door, re-approving rebuilt native controllers, and an outside program relying on a wire at 0.
  Raised the stale-program risk's likelihood to high for the user's own rebuilds. (autonomous)

## References

- ADR-13: outside wires stay compatible across versions
- ADR-14: P10, which "A permission whose meaning changes at 0" must keep
- ADR-06: layout file versioning, outside the freeze
- UTERM-062: "Callers that cannot name a tab"
