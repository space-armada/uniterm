# `post-status` at the producer limit is refused as "uniterm has no window to show the message"

**Status:** open
**Validation:** confirmed by reading the code; not reproduced in a test

## Observed

A script's `post-status` is refused with "uniterm has no window to show the message" while a window is open. This
happens once the active window holds 64 live script and applet status producers. The script raises that text, and
`uniterm run` exits 1. The message names the wrong cause.

## Cause

`post-status` gets its producer lazily through `producer(for:)` in
`Packages/UnitermKit/Sources/ScriptHost/ScriptHost.swift:1042-1051`. That calls `WindowSet.issueProducer`, which goes
to the active window's status center (`WindowKit/WindowSet.swift:619-621`). `StatusCenter.issueProducer` returns nil
once `issued.count` reaches `producerLimit` (`StatusKit/StatusCenter.swift:134-137`). The limit is 64
(`StatusKit/StatusMessage.swift:218`).

The handler treats every nil the same way. It replies `.failure(.refused, "uniterm has no window to show the
message")` (`ScriptHost/ScriptHost.swift:566-568`).

## Repro

Start 64 scripts that each post a status line and stay connected. Then start a 65th that posts one.

- Expected: a refusal that names the producer limit, or a post that succeeds.
- Actual, by trace: "uniterm has no window to show the message".

## Fix

Tell a missing window apart from the producer limit, and name the limit in its refusal. UTERM-047 rekeys script
sources by terminal session and bounds their state. Its M1 check "Sources that outlive their connections never use
up the producer limit" covers how often the limit is reached, but not this message.
