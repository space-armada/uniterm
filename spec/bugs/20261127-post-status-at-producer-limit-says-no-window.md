# `post-status` at the producer limit is refused as "uniterm has no window to show the message"

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27
**Estimate:** medium; no open design decisions. The producer issuer returns a result that tells a missing window from the limit. About 35 call sites change, nearly all test fixtures.

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

## Investigation notes

Triage run on 2026-11-27.

- The trace holds on the current code. `ScriptHost.producer(for:)` returns nil from `issueProducer(session.name)`
  (`ScriptHost.swift:1042-1051`). `ProducerIssuer` is `(String) -> StatusProducer?` (`ScriptHost.swift:17`), so nil
  carries no reason. `postStatus` refuses every nil with the no-window text (`ScriptHost.swift:566-568`).
- No test sets `producerLimit` through the script host. Only `StderrIngressTests.swift:169` sets it, for the status
  center alone. The failure was not run in the app.
- The fix changes the issuer's return type from an optional to a result with a "no window" case and a "limit" case.
  Every `ScriptHost` initializer call passes an issuer, about 35 sites, nearly all in tests.
- A regression test builds a host over a status center whose limit is already reached, posts a status, and expects a
  refusal that names the limit.

## Fix note

The script host's producer issuer now returns a `ProducerRequest` with three cases: issued, no window, and limit reached.
`post-status` refuses the limit case with a message that names the limit, and keeps the no-window text for a missing
window. Changed files: `StatusProducer.swift`, `StatusCenter.swift`, `WindowSet.swift`, `ScriptHost.swift`, and
`AppDelegate.swift`, plus the test fixtures that build a host. Two tests in `ScriptHelperIntegrationTests` cover both
refusals. The limit one failed before the fix.
