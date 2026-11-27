# ADR-18: Stored Data a Build Cannot Read Is Kept, and Never Acted On

**Status:** proposed
**Date:** 2026-11-26

## Context

uniterm writes data for itself and reads it back in later launches. Today that is the layout file, the controller
trust stores for packages and script files, and the browser's HSTS store. Planned work adds more, such as remembered
approvals for exec drivers in UTERM-066.

Builds of different ages read the same stores. A user may run a newer build, then an older one, then the newer one
again. Two builds may also run at once. A newer build writes entries an older build has never seen: a new kind of
approval, a new selector, a new node in the pane tree.

Today an older build fails a whole store over one such entry. The trust store grants nothing at all when it meets a
permission kind it does not know, and moves the whole file aside when it meets a selector it does not know. The layout
file is kept aside whole when its envelope is newer. Every readable entry is lost along with the unreadable one.
Splitting stores into more files works around that, but only until the next new kind.

ADR-06 already keeps an applet payload it cannot read as exact bytes, and writes it back unchanged. This ADR states that
rule for every store a build keeps for itself.

The guarantee starts at version 1. Before then, uniterm's formats may break as often as needed. From version 1, these
principles hold. A change that must break one of them is an explicit breaking change, with an automated migration
where one is needed.

## Principles

- **P1**: Data a build cannot read never costs it data it can read. A build that meets an entry it cannot read keeps
  using every other entry in that store. Failing a whole store punishes the user for having run a newer build, and
  makes every upgrade one-way.
- **P2**: Data a build cannot read is kept exactly as written, and written back unchanged. A round trip through an
  older build then loses nothing, and the newer build finds its data again.
- **P3**: A build acts on nothing it cannot read. An entry it cannot read grants no authority, runs nothing, and
  changes no behavior. Guessing what unknown data means could grant a power the user never gave, against ADR-14, or run
  a program the user never asked for, against ADR-03.
- **P4**: The unit a build keeps unread is a whole entry with a meaning of its own, never an unknown part inside an
  entry the build otherwise reads and acts on. An entry read with a part of it dropped is acted on with a meaning its
  writer did not give it. A reader can also drop unknown parts silently, as Swift's `Codable` drops unknown keys by
  default, so the loss would go unseen.
- **P5**: The user can see that a store holds data this build cannot read. An older build cannot edit or revoke what it
  cannot read. Without a sign of it, a user could believe an approval revoked, or a setting gone, while a newer build
  still holds it.

## Carve-outs

- **C1** (relaxes P1): when the entries a build can read depend on an entry it cannot read, the store is kept aside
  whole, and the build starts that store fresh. A pane nested inside a node of a kind the build does not know is one
  example. The readable entries have no meaning apart from the unreadable one, so there is nothing to keep using. P2
  still holds: the store is kept, not discarded.

## Consequences

- A store must let a reader tell where one entry ends and the next begins, so it can skip an entry it cannot read.
- The trust stores do not meet P1 today. The layout file meets P1 for applet payloads. Its envelope keeps the whole
  file aside on any newer version, which meets P1 only where C1 applies.
- Entries a build cannot read stay until a build that reads them rewrites or removes them. A user who wants one gone
  removes it in a build that understands it.
- Adding a new kind of entry no longer needs a new file or a new store version. A change to what an existing kind
  means still does.
- Stores a build keeps for itself are covered. Files a user saves and exchanges, such as exported tab sets, are
  documents with their own formats, and ADR-13 covers external wires.

## Alternatives Considered

- **Fail the whole store on any entry a build cannot read.** It is the simplest reader. It loses every readable entry
  along with the unreadable one, and in a trust store it removes every approval the user gave.
- **One file per kind of entry.** An older build never opens a file of a kind it does not know. Each new kind then
  needs a new file, and a new kind inside an existing file still fails the whole file.
- **Keep unknown parts inside entries the build reads.** Additive changes would need no new kind. ADR-06 rejected this
  for applet payloads: every reader must carry unknown parts through, and one careless reader loses data.
- **Bump the store's version on every addition.** An older build then refuses every store a newer build touched, which
  is the loss P1 forbids.

## References

- [UTERM-066](../proposals/UTERM-066-verified-identity-for-exec-drivers.md): originating proposal
- [UTERM-067](../proposals/UTERM-067-stores-keep-what-they-cannot-read.md): applies it to the trust stores
- [ADR-03](ADR-03-restored-state-never-runs-a-program.md): restored state never runs a program unasked
- [ADR-06](ADR-06-layout-file-versioning-and-schema-ownership.md): the layout file's payloads already follow P2
- [ADR-13](ADR-13-outside-wires-stay-compatible-across-versions.md): external wires
- [ADR-14](ADR-14-a-controller-controls-what-it-opened.md): remembered approvals and their scope
