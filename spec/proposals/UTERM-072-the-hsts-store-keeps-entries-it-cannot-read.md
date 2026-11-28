# UTERM-072: The HSTS Store Keeps the Entries It Cannot Read

**Status:** draft
**Created:** 2026-11-27
**Updated:** 2026-11-27

## Dependencies

- ADR-18, whose principles P1, P2, P4, and P5 this proposal applies to the browser's HSTS file
- UTERM-067, whose M1 found the gaps below
- UTERM-005, which built the browser's HSTS list

## Impacts

None.

## ADR Deviations

None.

## Summary

The HSTS file `Browser/hsts.json` keeps every host entry a build can read, and keeps the entries it cannot, written back
unchanged. Today one bad entry empties the list, and the next change overwrites the file.

## Motivation

UTERM-067 M1 checked the HSTS store against ADR-18.

- P1: `HSTSStore.load` decodes the whole list with `Codable`. One entry that fails to decode, such as a date that is not
  ISO 8601 or a missing field, throws. The store then starts an empty list. The file's version is read first. A version
  other than 1 leaves the whole list unused, though host entries rarely change meaning.
- P2: after an undecodable load, the next `record` or `removeAll` calls `persist`. It writes the new list over the file,
  and every entry that file held is gone. A file at another version is the exception, and stays untouched.
- P3: an unread entry is never used. A lost entry also means a host is no longer upgraded to HTTPS, which is a missing
  protection and not a granted power.
- P4: `Codable` drops a key it does not know, in an entry and at the top. The next save drops it silently, and the
  version stays 1.
- P5: nothing shows that the file held an entry this build could not read. A clear through Clear Website Data returns
  false for a newer file, and gives no sign for a damaged one.

The store's own doc comment says a lost entry is "a missing hint rather than lost user data". ADR-18 P2 holds for every
store a build keeps for itself, and the guarantee starts at version 1.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### What an entry this build cannot read does

Candidates:

- Keep the entry as exact bytes, write it back, and use every other entry. The file's reader needs to find where an
  entry ends, as the trust stores' reader does under UTERM-067.
- Keep the list as it is, and record that an HSTS entry is a hint that expires, so a lost one is renewed by the next
  header. This drops P2 for this store. It needs the user's decision, since ADR-18 carves out no such store.
- Move the file aside whole when it cannot be read, as the layout file does, and start an empty list. This keeps P2 and
  drops P1.

### What a newer version does

Candidates:

- Read it as an older version, per entry, and keep what this build cannot read. The version moves only when an existing
  field changes meaning.
- Keep today's rule: a newer file is left untouched, and the list stays in memory.

### Whether the window shows a count

Candidates:

- Show a count of kept entries beside Clear Website Data, as UTERM-067 does for the trust stores.
- Show nothing. HSTS entries grant no authority, and the user never edits them.

### Whether Clear Website Data removes kept entries

Candidates:

- It removes every entry, kept ones included, since the user asked to clear all data. This needs the answer to ADR-18
  P2's "removes it in a build that understands it".
- It removes only entries this build reads.

## Risks

- **A host loses its upgrade after a bad read** — likelihood: low, impact: medium. A host reads as plain HTTP until its
  next header. Mitigation: the entries a build can read stay in use.
- **Keeping bytes grows the file** — likelihood: low, impact: low. The list holds at most 2,048 hosts.

## Milestones

### M1: The HSTS file keeps what it cannot read

**Status:** NOT STARTED

- One entry this build cannot read leaves every other host in the list in use
- An entry this build cannot read is written back byte for byte on the next change
- A file that is not JSON is kept aside with a notice, and a fresh list starts
- Clear Website Data states what it did to kept entries
- The user can see that the store holds entries this build cannot read, or the As built block records the decision that
  they cannot

## Decision Log

- 2026-11-27: Filed as a draft from UTERM-067 M1. The check of every store found the HSTS store short of ADR-18 P1, P2,
  P4, and P5. Nothing is decided.

## References

- ADR-18: stored data a build cannot read is kept, and never acted on
- UTERM-005: the browser applet
- UTERM-067: stores keep what they cannot read
