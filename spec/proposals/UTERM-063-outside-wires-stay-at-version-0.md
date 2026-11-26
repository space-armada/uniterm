# UTERM-063: Outside Wires Stay at Version 0 Until Declared Stable

**Status:** draft
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Impacts

- ADR-13 — needs the amendment in "ADR-13 at version 0". Its P5 names version 4 for the exec wire and 14 for
  ScriptWire, which this proposal resets.
- UTERM-028, UTERM-056 — accepted, not started. They negotiate versions on the exec wire and ScriptWire. While a wire is
  at 0 there is nothing to negotiate, so neither is needed until that wire is declared 1.
- UTERM-006, UTERM-019, UTERM-024, UTERM-026, UTERM-029, UTERM-030, UTERM-032, UTERM-040, UTERM-048, UTERM-050,
  UTERM-054, UTERM-055, UTERM-057, UTERM-062 — each plans a new version of a wire or an applet command schema. While
  that wire or schema is at 0, the change lands in place instead.

## Summary

ScriptWire, the exec wire, and every applet command schema reset to version 0, and stay there through breaking changes.
Version 0 carries no compatibility promise. A wire leaves 0 only when the user declares it version 1, separately from
uniterm's own release. A check fails the build when a version moves without that declaration.

## Motivation

uniterm is at 0.1.0, and nobody outside the user depends on its wires. Yet ScriptWire is at version 14, the exec wire at
4, and the viewers' command schemas at 1.0. Each number counts breaking revisions made before anyone needed them kept.
ADR-13 then promises compatibility from those numbers on, so every later change to a wire pays for version splits and
negotiation that serve no deployed program. UTERM-062 showed the cost: requiring programs to name a tab needed a
compatibility rule for programs that do not exist outside the user's own.

## Design Decisions (Settled)

### Every wire and schema is at version 0

Decision: ScriptWire, the exec wire, and every applet command schema reset to version 0. A schema's version is 0.0.
Every program built against an earlier build must be rebuilt or rewritten against this one. The user chose this on
2026-11-26.

Rationale: version 0 means "no compatibility promise", as in semantic versioning. Resetting now, before any other
proposal bumps a version, makes one break instead of many.

### Version 0 never bumps

Decision: while a wire or schema is at 0, a breaking change lands in place, and the version stays 0. The user chose
this on 2026-11-26, over semantic versioning's 0.y, where the minor still moves.

Rationale: a bump at 0 promises nothing, so it only adds noise and the temptation to keep old versions alive. The cost
is that a frozen number cannot tell an old program from a new one at the handshake. See "Errors name the mismatch".

### A wire reaches version 1 only when the user declares it

Decision: each wire and each applet command schema leaves 0 only when the user declares it version 1. Each is
declared on its own, and none is tied to uniterm's own release. From version 1 on, ADR-13 applies to it in full.

Rationale: a protocol is ready to promise compatibility when its shape has settled, which can come before or after the
app's 1.0. The user asked that no version move again unless they say so.

### Errors name the mismatch

Decision: since the handshake no longer catches a stale program, each wire's decoder refuses a message it cannot read
with an error that names the field or message that did not match. It says the program must be rebuilt against this
uniterm build. A message from a stale program never acts on a guess.

Rationale: a stale program now passes the handshake and fails on the first message whose shape changed. An error that
names the field and the fix is the only signal left.

### The build enforces the freeze

Decision: a check, run by `make check` and CI, fails when any wire's or schema's version differs from 0, unless that
wire or schema is listed as declared stable. The list lives in the repository and starts empty. Only the user adds to
it, as the declaration of version 1. The project's instructions point at the check.

Rationale: an instruction alone is forgotten by the next session that bumps a version out of habit. A failing check
cannot be.

### ADR-13 at version 0

Decision: this proposal asks the user to amend ADR-13 with the following carve-out, and to update P5. The amendment
applies once the user approves its text.

> **C1** (relaxes P1, P2, P3, and P5): a wire, or a contract a wire carries, at version 0 carries no compatibility
> promise. Its meaning may change in place, without a new version, and an older program may stop working. Version 0
> marks a protocol whose shape has not settled, and no program outside the project depends on it yet. The principles
> apply from the version the user declares 1.

> **P5** (updated): the rule holds from version 1 of each wire and each contract it carries.

Rationale: ADR-13 would otherwise require a new version for every change, which version 0 exists to avoid.

## Design Decisions (Open)

None. Every question is settled.

## Risks

- **Programs built against an earlier build stop working** — likelihood: high, impact: low.
  Accepted: the only such programs are the user's own, and the user chose the break on 2026-11-26.
- **A stale program passes the handshake and fails later** — likelihood: medium, impact: low.
  Mitigation: "Errors name the mismatch" makes every such failure name the field and the fix.
- **A later proposal bumps a version out of habit** — likelihood: high, impact: low.
  Mitigation: the build check fails, and names the declared-stable list.

## Milestones

### M1: Reset to version 0 and freeze

**Status:** NOT STARTED

- ScriptWire, the exec wire, and every applet command schema report version 0, and a schema reports 0.0
- The bundled `uniterm` command, the Janet helper, every test fixture, and every example driver and controller in the
  repository speak version 0
- A message the decoder cannot read is refused with an error that names the field or message and says to rebuild
  against this build
- `make check` and CI fail when any version differs from 0 and its wire or schema is not on the declared-stable list.
  The list exists, empty, and the project's instructions name it
- ADR-13 carries the amendment the user approved, or the milestone waits for it
- The impacted proposals that plan a version bump say the change lands in place while the wire is at 0

## Decision Log

- 2026-11-26: Drafted from the UTERM-062 review. The user chose to reset every wire and schema to version 0, to keep
  them at 0 through breaking changes, and to declare version 1 for each wire separately from uniterm's release.

## References

- ADR-13: outside wires stay compatible across versions
- UTERM-062: "Callers that cannot name a tab"
