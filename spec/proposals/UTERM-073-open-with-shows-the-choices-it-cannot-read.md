# UTERM-073: Open With Shows the Choices It Cannot Read

**Status:** draft
**Created:** 2026-11-27
**Updated:** 2026-11-27

## Dependencies

- ADR-18, whose principle P5 this proposal applies to the saved Open With choices
- UTERM-015, which built the Open With chooser and its saved choices
- UTERM-067, whose M1 found the gap below

## Impacts

None.

## ADR Deviations

None.

## Summary

The user can see that the saved Open With choices hold an entry this build cannot read, and can clear it. Today the
chooser drops such an entry from view, so it can neither show nor clear it.

## Motivation

UTERM-067 M1 checked the `openWithChoices` defaults key against ADR-18. Each entry reads on its own, and a save writes
every other entry back as stored. P1 to P4 meet.

P5 falls short. `SavedChoiceStore.choices()` keeps only entries whose value is a non-empty string. An entry with any
other value never reaches `hasStoredChoice`, so the chooser offers no clear for it. A build that cannot read an entry
a newer build wrote, such as one that holds a record in place of an applet type ID, shows no sign of it.

The gap costs no authority, since a choice only picks which applet opens a file. ADR-18 relaxes only P1 through C1, so
the gap is still a gap.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### What the user sees for an entry this build cannot read

Candidates:

- Treat a stored value of any kind as a stored choice for its type. The chooser offers to clear it, and routing ignores
  it. This is the plain behavior, and it reuses the clear the chooser already has.
- Show a count of unread choices in the Settings window.
- Show nothing, and record that a choice that changes no authority needs no sign. This drops P5 and needs the user's
  decision.

## Risks

- **A clear removes a choice a newer build reads** — likelihood: low, impact: low. A clear is the user's own action on a
  choice for one type. Accepted: the user asked for it.

## Milestones

### M1: The chooser shows a choice it cannot read

**Status:** NOT STARTED

- An entry whose value is not a string is shown as a stored choice for its type, and the chooser offers to clear it
- Routing never acts on an entry this build cannot read
- Saving or clearing one choice leaves every other entry as stored

## Decision Log

- 2026-11-27: Filed as a draft from UTERM-067 M1. The check of every store found a P5 gap in Open With. Nothing is
  decided.

## References

- ADR-18: stored data a build cannot read is kept, and never acted on
- UTERM-015: cross-applet file opening
- UTERM-067: stores keep what they cannot read
