# Unanswered reviews hold connection slots until every script is refused

**Status:** rejected 2026-11-27
**Rejected:** the slots fill only when the user's own program is started 32 or more times and every one of its
reviews is left unanswered. Each waiting review is in Pending Requests, where the user sees it and can answer or deny
it, and each slot frees when its program exits. Filling the slots takes the user scheduling a program and then ignoring
every request it makes. uniterm does not design around a user misconfiguring their own programs. Raise it again only
with a case that fills the slots without that.

## Observed

Found by a design critique of UTERM-069 on 2026-11-26. A program that waits on a review, or on Grant Access, keeps its
socket connection open until the user answers or the program exits. The listener serves at most 32 connections at
once. A program started every minute by cron, with nobody answering, holds one more slot each minute. After about 32
minutes every later connection is refused as too many, including the user's own scripts started in tabs.

## Cause

- `ScriptListener.maxConnections` is 32, and `admit` refuses a connection once 32 are served
  (`Packages/UnitermKit/Sources/ScriptHost/ScriptListener.swift:13`, `205-212`).
- A waiting review has no deadline. The command says "The user may take as long as they like, so the wait has no
  timeout" (`Packages/UnitermKit/Sources/ScriptRuntime/ScriptSession.swift:115`).
- Pending requests of unbound connections are bounded only by the same slots: "Each connection holds one of the
  listener's slots, so the list never passes the listener's limit" (`ScriptHost.swift:106-112`).

## Repro

1. Leave uniterm running, with no answer given in Pending Requests.
2. From outside uniterm, start an untrusted `uniterm controller run` or an unbound script client once a minute.
3. Expected: the user's own script in a tab still connects. Actual, as traced: after 32 waiting connections, the
   listener refuses every new connection.

## Fix

Bound waiting reviews below the listener's limit, so slots stay free for programs that need no review. Design calls:

- Where the bound sits: a fixed number of waiting reviews, or per program identity, so one repeating program cannot
  take every waiting slot.
- What a program past the bound sees: a refusal that names the waiting reviews, or the oldest waiting review ending.

UTERM-069 adds a Deny keyed on a direct client's identity, so a denied repeating client stops taking slots. That covers
a client the user denied, not one nobody has answered.
