# The second-Ctrl-C test sometimes sees the first Ctrl-C end the script

**Status:** open
**Triaged:** 2026-11-15 (not reproducible; see investigation notes)
**Validation:** not confirmed. Seen twice in full package runs, on 2026-11-14 and 2026-11-27. It passed alone and in
another full run.

## Observed

`ScriptLimitsTests.testASecondCtrlCEndsAScriptStuckInACallTheInterruptNeverReaches` failed once during a full
`swift test` run of the package on 2026-11-14. Both of its checks after the first SIGINT failed:

- `the first Ctrl-C ended a call the interrupt cannot reach` (`ScriptLimitsTests.swift:139`)
- standard error read `stuck-in-c.janet: interrupted`, not `interrupted again` (`ScriptLimitsTests.swift:146`)

So the first interrupt stopped the script, the way it does before the blocking read begins. The same test passed in a
full run about ten minutes earlier, on the same code. It also passed when its suite ran alone right after the failure.
The run's other changes were in the strict JSON reader, which this test does not use.

## Suspected cause

The test sends the first SIGINT once `waitUntilBlocked` reports the helper's main thread is blocked
(`ScriptLimitsTests.swift:129-131`). Under load, that check may pass while the thread is blocked somewhere other than
the read, such as writing the marker. The interrupt then lands before the read and ends the script at the call.

Not traced. A product race, where the interrupt hook reaches the read after all, is not ruled out.

## Next step

Read `waitUntilBlocked` and what it samples. Then run the full package suite several times and see whether the failure
recurs, and in which order.

## Investigation notes

Triage run on 2026-11-15.

- No separate regression test exists. The failing test is the only one that covers this path.
- The test passes alone on the current build: 1 test, 0 failures, 1.07 s.
- A full-suite repeat was not run, so the failure did not recur.
- `waitUntilBlocked` polls `mainThreadIsWaiting` every 10 ms. That reads the oldest thread's run state and returns true
  for `TH_STATE_WAITING`. It does not say what the thread waits on.
- The fixture writes the marker with `spit` and then reads stdin. `spit` is local to the helper, not an app call. So
  the helper has no app reply to wait on between the two steps.
- A short kernel wait after the write, such as closing the file or a page fault under load, would still read as
  waiting. The first SIGINT could then land before the read begins. That matches both symptoms in the report.
- This is a hypothesis about test synchronization. A product race is not ruled out.
- Next step: run the full package suite several times in the original order and note whether the failure recurs.
  If it does, make the test wait for the read itself, for example by having the fixture signal after the read begins.

## Second sighting

On 2026-11-27 the test failed again during `make ci-package`, in a landing worktree for a batch of data viewer commits.
That batch does not touch ScriptHost. The same two symptoms showed: the first Ctrl-C ended the call, and standard error
read `stuck-in-c.janet: interrupted`. The watchdog state also read `reaped` where the test expects `sent`
(`ScriptLimitsTests.swift:137`). Every other package test passed in that run.
