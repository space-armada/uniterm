# UTERM-063: External Versions Stay at 0 Until Declared Stable

**Status:** implemented
**Created:** 2026-11-26
**Updated:** 2026-11-27

## Impacts

- ADR-13 — needs the amendment in "ADR-13 at version 0". Its P5 names version 4 for the exec wire and 14 for
  ScriptWire, which this proposal resets.
- ADR-16 — proposed. Its Consequences say a changed answer is a new version under ADR-13. While the wire is at 0, the
  change lands in place under "A changed meaning is refused, never reinterpreted".
- UTERM-028, UTERM-055 — accepted, not started. Their exec frames land in place at version 0, after M2, with no version
  offer. The user chose this for UTERM-028 on 2026-11-26.
- UTERM-056 — deferred until ScriptWire's declaration. While ScriptWire is at 0 there is nothing to negotiate. Its one
  piece of work at version 0, the advice in the hello refusal, lands in M2.
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
compatibility promise. An older program is refused, never reinterpreted. An external version leaves 0 only when
uniterm's maintainers declare it version 1, separately from uniterm's own release. A check fails the build when one
moves without that declaration. Internal versions, which only uniterm reads, keep their own rules.

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

### An external version reaches 1 only when uniterm's maintainers declare it

Decision: each external version leaves 0 only when uniterm's maintainers declare it version 1. No version moves
automatically, and none moves because a proposal changes something. Each is declared on its own, and none is tied to
uniterm's own release. From version 1 on, ADR-13 applies to a wire in full, and every other external version follows its
own rule. The user chose this on 2026-11-26.

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

Internal: only uniterm reads the version. These keep their own rules, and stay out of the freeze and the check.

- DocumentWire and ImageWire. The app and its document and image helpers ship in one bundle, so they keep exact-match
  bumps
- The layout file's envelope version, and each applet's saved state inside it, under ADR-06
- The map's command-pin snapshot and the browser's HSTS store
- The controller policy file's format. uniterm writes it when the user approves a controller, and reads it back
- Each permission kind's edition, which uniterm records with each approval. See "Permissions carry no version"

The check reads a named list of constants: ScriptWire's and the exec wire's versions, each registered applet command
schema's version, `uniterm/api-version`, and the descriptor format. It never greps for the
word "version".

Rationale: the user's goals are about what outside programs see. Version 0 tells an author the interface is unstable.
Their programs would otherwise depend on numbers that count unpublished revisions. An internal version is internal in
the sense that only uniterm needs to know it. Nobody outside reads its number, so it says nothing about stability to
anyone, and its bumps cost no author anything. DocumentWire and ImageWire keep their exact match, which tells two builds
apart when the bundle is replaced under a running app.

### The controller policy file at the reset

Original question: the policy file stores each approval as a permission kind and version, all at 1 today. After the
reset this build knows only version 0. It reads a pre-reset file as written by a newer uniterm, then remembers no trust
and saves none, and leaves the file as it is. What should the reset do with such a file?

Decision: set a pre-reset policy file aside with a notice, as a broken file is today. Every controller is approved
again once. The user chose this on 2026-11-26. The reset tells a pre-reset file apart by the store's format number, not
by a scope's version: whichever of this proposal's M1 and UTERM-067 lands second moves that number. Amended 2026-11-26;
see Decision Log.

Rationale: the decision touches only files written before the reset, which in practice means the user's own. The user
does not need those approvals kept.

### Permissions carry no version

Original question: ADR-14 P10 says a change in a permission's meaning cannot widen an existing approval without the
user's consent. Today a changed meaning is a new permission version, and a stored approval names the old one, so it does
not cover the change. At a frozen 0 the version cannot carry that. How does a changed permission keep old approvals
from covering it?

Decision: a controller's descriptor names each permission by its kind alone, with no version. A permission always means
what the running uniterm says it means. uniterm keeps an internal edition for each permission kind, and records it with
each approval in the policy file. When a kind's meaning grows, its edition moves. An approval made at an older edition
no longer covers that kind, so the user is asked again. Declaring permissions stable later is a promise about how
uniterm changes a meaning, not a number in the descriptor. The user chose this on 2026-11-26.

Rationale: the edition is an internal version, since only uniterm reads it, so it may move. ADR-14 P10 holds, because
an old approval never silently covers a bigger power. An author-written version at 0 would be the same constant in
every descriptor and add nothing. Format 1 descriptors already carry no permission version.

Leaves undone: a controller cannot say which edition it needs. A controller on an older uniterm, where a permission
means less, finds out at the first call that is refused by name, not at install.

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
unaffected. The app tells the bundled command from a native controller by the peer's executable path. A program that
runs from the app's own command path must present its identity, and is refused when it presents none. A program from any
other path may present none, and is admitted as before. A program that presents an identity is compared with the kept
one wherever it runs. The check fails closed: a program whose path the kernel cannot name, and that presented no
identity, is refused, and an identity with no command path refuses every program. A command that was unreadable at
launch stays unreadable for the life of the process. A swapped command copied to another path that sends no identity is
admitted as a generic peer, as any native-style peer is. The begin-time check of the peer's code still gates controller,
file, undeclared, and question sessions. A plain `begin` script session and a REPL's non-token path are not gated by it.
(autonomous) Amended 2026-11-27; see Decision Log.

Rationale: replacing the bundle under a running app pairs an old app with a new command. The exact version match caught
this before, and ScriptWire's code documents the refusal. At a frozen 0 both sides say 0. Without this check the first
call may run before a later one fails, or a call that keeps its bytes runs under a new meaning. ADR-13 P6 already lets
the bundled command's messages refuse every build but their own. Today the app re-reads the command on disk and adopts
it, which would let a swapped command pass, so that path goes.

### The build enforces the freeze

Decision: a check, run by `make check` and CI, fails when any version the freeze covers differs from 0, unless that
external version is listed as declared stable. The list lives in the repository and starts empty. Only uniterm's
maintainers add to it, as the declaration. The project's instructions point at the check.

Rationale: an instruction alone is forgotten by the next session that bumps a version out of habit. A failing check
cannot be.

### ADR-13 at version 0

Decision: ADR-13 is amended with the following text. The user approved C1 and the rename to "external wire" on
2026-11-26, and gave P5's wording. M1 applies it. Amended 2026-11-26; see Decision Log.

> **C1** (relaxes P1, P2, P3, and P5): a wire whose protocol is at version 0 carries no compatibility promise. A change
> may land in place, without a new version, and an older program may stop working. An older program's message is still
> read with its old meaning or refused, never reinterpreted, which keeps P1's reason. Version 0 marks a wire whose shape
> has not settled, offered to no program outside the project. A contract the wire carries keeps its own rule, per P4.

> **P5** (amended): the rule holds for each wire from version 1. A wire reaches version 1 only when uniterm's
> maintainers declare it stable. Until then it is at version 0, under C1.

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

None. Every question is settled.

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
  names format 1 or 2, and format 2 permissions name version 1. After the reset each descriptor names format 0 and its
  permissions name no version, and each package is signed again.
  Accepted: the only packages are the user's own and the repository's fixtures, and M1 rewrites the fixtures.
- **A session adds to the declared-stable list to make the check pass** — likelihood: medium, impact: medium.
  Mitigation: the project's instructions say only uniterm's maintainers add to the list, and an addition shows in the
  diff they review.
- **A program built before the reset names version 1** — likelihood: low, impact: medium. After uniterm's maintainers
  declare an external version 1, a program or script from before the reset that still names 1 or 1.0 passes the version
  check under the new meaning. A script that checks `(uniterm/api-version)` against 1 does the same. Accepted: the user
  chose version 1, and such programs are the user's own.
- **Declaring a wire stable is a one-way door** — likelihood: medium, impact: medium. From version 1, ADR-13 holds the
  wire to P1 through P3, so its next change needs a version negotiation. UTERM-056's is planned for ScriptWire, and
  the exec wire has none. Mitigation: only uniterm's maintainers declare, and each negotiation is designed at its
  wire's declaration, so the cost is in front of the user when they declare.
- **Every in-place change makes the user re-approve rebuilt native controllers** — likelihood: high, impact: low. A
  stale native controller must be rebuilt, which changes its version digest, and ADR-14 P9 ties a remembered approval
  to that digest. Accepted: the only native controllers are the user's own, and a rebuild already asks today.
- **An outside program relies on a wire at 0** — likelihood: low, impact: medium. C1 rests on no outside program
  relying on a wire at 0. Accepted: the user stated on 2026-11-26 that the only such programs are their own, and a wire
  someone else needs is declared stable first.

## Milestones

### M1: Reset to version 0 and freeze

**Status:** DONE

No external interface changes shape in this milestone, so a pre-reset program is refused at the hello, and two builds at
0
agree on every message.

- ScriptWire, the exec wire, every applet command schema, and the controller descriptor format report version 0, and
  a schema reports 0.0. DocumentWire and ImageWire keep their versions
- A descriptor names each permission by kind alone, and one that names a permission version is refused by name. Janet
  code and fixtures that name a permission name its kind alone
- uniterm keeps an edition for each permission kind and records it with each approval. A test grows a kind's edition
  and checks that an approval made at the older edition no longer covers it, and the user is asked again
- A protocol-mismatched exec hello is never admitted on its placeholder schema of 0.0
- `uniterm/api-version` reports 0, and its doc says it stays at 0 until uniterm's maintainers declare it
- A policy file written before the reset is set aside with a notice, and the next approval is saved. The file is told
  apart by its format number. This milestone moves the format from 1 to 2, and UTERM-067 M2 moves it again to 3, so no
  pre-reset scope is ever read as an edition. Amended 2026-11-27; see Decision Log.
- The bundled `uniterm` command, the Janet helper, every test fixture, and every example driver and controller in the
  repository speak version 0, `Tests/ExecTestSupport/Fixtures/driver.pl` and the controller package fixtures included.
  Tests that compute an older version as the current one minus 1 still work at 0
- `make check` and CI fail when any version the freeze covers differs from 0 and is not on the
  declared-stable list. The check reads the named constants, and covers every registered applet command schema,
  `uniterm/api-version`, and the descriptor format
- The declared-stable list exists, empty, and the project's instructions name it
- The check leaves every internal version alone: DocumentWire, ImageWire, the layout and payload versions, the
  command-pin snapshot, the HSTS store, and the policy file format
- The version docs on ScriptWire, the exec wire, and the command schema version describe version 0 and 0.0
- ADR-13 carries the amendment the user approved
- ADR-13 says "external wire" where it said "outside wire", its title included, as a change of wording with no change of
  meaning. Its filename and the quoted text in its Amendments stay as they are
- `docs/glossary.md`'s "Wires" section is titled "Wires and versions", and carries these entries:
  - **External wire**, replacing "Outside wire": a wire to a program deployed apart from uniterm, ScriptWire and the
    exec wire. Its version is an external version. At version 0 it makes no compatibility promise. From version 1 it
    stays compatible across versions, per ADR-13
  - **Internal wire**: a wire whose two ends ship in the uniterm bundle, DocumentWire and ImageWire. Its version is an
    internal version, and it refuses any version but its own
  - **External version**: a version that a program or file uniterm does not build names or checks. These are
    ScriptWire's, the exec wire's, each applet command schema's, `uniterm/api-version`, the controller descriptor
    format. It stays at 0 until uniterm's maintainers declare it version 1, per UTERM-063
  - **Internal version**: a version only uniterm reads, such as an internal wire's, the layout file's, and a
    permission kind's edition. It keeps its own rules
  - **Declared stable**: an external version uniterm's maintainers have declared version 1. Its compatibility promise
    holds from then on
- ADR-16's consequence line says a changed answer lands in place while its wire is at 0
- UTERM-056 is deferred until ScriptWire's declaration. UTERM-028 and UTERM-055 land their frames in place
  at 0, with no version offer
- The impacted proposals that plan a version bump say the change lands in place while the wire is at 0, after M2

**As built:**

- The policy file's format moved from 1 to 2 and a scope stores its edition. A file in an earlier format is set aside
  with a notice. See the Decision Log entry for 2026-11-27 (run best guess) on the policy file format.
- An approval covers a request only at the edition it was made at. An older edition reads and covers nothing, and an
  edition above the build's reads as newer. UTERM-067 M2 narrows the newer case to one entry. Not built here.
- A hello at another exec protocol version decodes to its own case that carries no schema. The channel refuses it
  before any schema check, so the placeholder schema 0.0 can never admit a hello. The refusal text names both versions.
- The descriptor reader refuses a permission that names a version, by name, in a package and in a script file.
- `controller.sig`'s own format number stays 1. It is not in the freeze list, and the check does not read it. It names
  the signature file format that controller authors' tools write, so it may belong on the list. That is the maintainers'
  call.
- The `janet-hello` fixture is signed again. An Ed25519 signature from CryptoKit differs on every run, so the new
  signature is a new value. The descriptor digest and the key fingerprint reproduce on every run. The method is in
  `ControllerFixtures.swift`.
- ADR-18 also said "outside wires", and now says "external wires". No other live prose in docs, ADRs, or the README
  used the old term.

### M2: Refuse stale programs by name

**Status:** DONE

These guards are changes at version 0, so C1 covers them. No other in-place change lands before this milestone.

- Every uniterm decoder on ScriptWire and the exec wire refuses a key, field, tag, or message type it does not know,
  with an error that names it and says to rebuild the program or update uniterm
- ScriptWire bodies with trailing bytes are refused by name. A positional field whose meaning changes takes a new
  message tag, since the field itself has no name
- The strict exec decoder still reads both forms of the `error` message's text, `error.message` and `message`
- A pre-reset exec hello with extra keys is refused with the version text, not an unknown-key error. Each peer reads the
  hello's version field first, and a test refuses a hello from another version with both versions named
- The app's notice for a ScriptWire hello at another version names both versions, and says to rebuild the program
  against this uniterm or update uniterm, as the exec wire's refusal does. It never says to relaunch uniterm, since the
  identity check catches the bundle's own command. It never picks one remedy by comparing the numbers, since a
  pre-reset program's version is above 0
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

**As built:**

- ScriptWire refuses an unknown or retired message tag, call tag, enumerated value, and trailing byte by name, with text
  that says to rebuild the program or update uniterm. `token`, the two digests, and the new identity read exactly their
  size, so a longer body is refused as trailing bytes. A reply's payload and a send's content are the rest of their body
  by design, and each is read to its end by its own decoder. A hello of another version is read for its version alone,
  in both directions.
- The exec decoder knows each message's keys and refuses any other by name. A command without `pane` also refuses
  `applet` and `schema`, which mean something only with a pane. Both forms of an error's text still read. A hello reads
  its protocol first, and one at another version never reaches the key check.
- Each wire has a table of retired names, empty. Each wire's test sends every entry of its table, and also builds a table
  of its own, so the refusal is proved while the shipped table is empty.
- The hello refusal on the app and on the command names both versions and says to rebuild or update. It never says to
  relaunch and never compares the numbers.
- The identity is the command's code directory hash, in one message that follows the hello and comes before any
  declaration. The app tells the bundled command from a native controller by the peer's executable path. See the
  Decision Log entry for 2026-11-27 (run best guess) on the executable-path rule.
- The app's own command is read when its identity is made at launch, in the background. The listener waits for that read
  before it serves a connection. A command that appears on disk later is never adopted. The check fails closed. See the
  Decision Log entry for 2026-11-27 (run best guess) on the fail-closed identity check.
- The helper and the REPL print the refusal text they are sent. A REPL reads it as an attach refusal.

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
- 2026-11-26: A pre-reset controller policy file is set aside, and every controller is approved again once. The user
  chose this, since only files from before the reset are affected.
- 2026-11-26: M1 adds glossary entries for external and internal wires, external and internal versions, and declared
  stable. "Outside wire" becomes "external wire" in the glossary and in ADR-13, to match the external and internal
  versions. The user chose this.
- 2026-11-26: Permissions carry no version in descriptors. uniterm tracks an internal edition per kind, and an approval
  made at an older edition is asked again. The user chose this over two other options: a new kind name for a changed
  meaning, and leaving permission versions out of the freeze.
- 2026-11-26: The user approved the ADR-13 amendment's C1 and the rename from "outside wire" to "external wire". The
  user corrected P5's draft, "the rule holds from version 1 of each wire, which the user declares": no wire is declared
  yet, and uniterm's maintainers declare, not its users. P5 now says a wire reaches version 1 only when uniterm's
  maintainers declare it stable, and is at version 0 under C1 until then. Every forward-looking "the user declares" in
  this proposal now says "uniterm's maintainers declare".
- 2026-11-26: Accepted. The user chose to advance it at the end of the review. No decision earns a new ADR: the
  lasting rules go into ADR-13's amendment.
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
- 2026-11-26: Scheduled as M1-M2 in queue.md, before UTERM-043 M1.
- 2026-11-26: UTERM-028 no longer waits on the exec wire's declaration. The user chose that its driver commands land in
  place at version 0, and UTERM-055's capture frames follow. Impacts, the one-way door risk, and M1's check on the
  impacted proposals now say so.
- 2026-11-26: M2 gained the check that ScriptWire's hello refusal gives the advice that can work. Today the app posts
  "Relaunch uniterm" for any hello at another version. After the reset that comes from programs built outside the
  bundle, which a relaunch cannot fix. The fix came from UTERM-056 M3, whose remaining work waits on ScriptWire's
  declaration. The user chose to land it here, so the wrong text never ships after the reset. Leaves undone: a user who
  swaps an older uniterm under a running app is told to rebuild or update, not to relaunch.
- 2026-11-26: Amended "The controller policy file at the reset" and its M1 check for UTERM-067, whose reader keeps an
  entry it cannot read instead of reading the whole file as newer. A pre-reset file was told apart only by scopes at a
  version this build does not know. It is now told apart by the store's format number, which the later of M1 and
  UTERM-067 moves. Otherwise a pre-reset scope at version 1 could later be read as edition 1 of its kind. The M1 check
  said before: "A policy file written before the reset is set aside with a notice, and the next approval is saved".
- 2026-11-27 (run best guess): The policy file format moves from 1 to 2 in M1, for both `policy.json` and `files.json`,
  and a scope stores its edition in place of a permission version. A file in an earlier format is set aside with a
  notice that each controller or script file is approved again once, and the next approval is saved. A newer format
  stays untouched. The decision "The controller policy file at the reset" stands as the user wrote it. Its rule that
  whichever of M1 and UTERM-067 M2 lands second moves the number does not forbid the first one from moving it too. M1
  landed first and moves it to 2, and UTERM-067 M2 then moves it to 3. M1's check on the policy file said before: "The
  file is told apart by its format number, which this milestone moves when it lands after UTERM-067, so no pre-reset
  scope is ever read as an edition". It now says what M1 does. Either order breaks the file twice, as UTERM-067's risk "Every approval is given again once" says.
- 2026-11-27: M1 built. Each impacted proposal that plans a version change was amended to land in place, and each
  carries its own Decision Log entry. UTERM-019 and UTERM-050 hold a decision the user made, so each keeps its text and
  carries a pending override that cites this proposal's user decisions of 2026-11-26. UTERM-028, UTERM-055, UTERM-062,
  UTERM-064, and UTERM-056 already said so.
- 2026-11-27 (run best guess): The app tells the bundled command from a native controller by the peer's executable
  path, which the kernel reports. The decision said only that programs built outside the bundle send no identity and
  are unaffected, and left open how the app knows which peer must send one. A peer at the app's own command path must
  send one. A peer at another path may send none. A peer that sends one is compared wherever it runs, so a command
  copied from another install is refused with the app's own command path. If the guess is wrong, a native controller
  that happened to run from the app's command path would be refused, and a command from another install that sent no
  identity would be admitted as a generic peer. ADR-13 P6 and the existing begin-time check of the peer's code still
  gate controller, file, undeclared, and question sessions, so an admitted generic peer gets no more than before. A
  swapped command copied to another path that sends no identity is admitted as a generic peer. A plain `begin` script
  session and a REPL's non-token path are not gated by that check.
- 2026-11-27 (run best guess): The identity check fails closed, and a command unreadable at launch is never re-read.
  Trace: `ProcessInspection.executablePath(of:)` returns nil when the kernel cannot look the process up, which happens
  for a peer that has already exited, so a live same-user peer is named in practice. `BundleHelperIdentity.commandPath`
  is never nil, since it is the bundle URL's path. Only an identity with no path, such as a test fake, returns nil. Even
  so, a nil peer path with no presented identity would have passed a stale command at the app's own path, so it is now
  refused with text that says the app could not tell where the program runs. A nil command path now refuses every
  program. Native controllers lose only when the lookup itself fails. A failed launch read is kept for the life of the
  process, so `keptCodeDirectoryHash()` stays nil and the refusals for an unreadable command apply. The text said before
  that a failed read is not kept and the next call reads again, which could adopt a command that appeared later. If the
  guess is wrong, a native controller whose path lookup failed would be refused until it reconnects.

## References

- ADR-13: outside wires stay compatible across versions, renamed to external wires in M1
- ADR-14: P10, which "Permissions carry no version" keeps
- ADR-06: layout file versioning, outside the freeze
- UTERM-062: "Callers that cannot name a tab"
