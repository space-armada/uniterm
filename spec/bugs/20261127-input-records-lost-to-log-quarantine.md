# The unified log can drop every input record of a UI test iteration

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27
**Estimate:** small to medium; one non-trivial decision, which of the four fixes below to take. The user chose the first two together.
**Validation:** confirmed on 2026-11-27 in a local run of 40 iterations, where 1 was quarantined

## Observed

The app's input records go to the unified log. The log can quarantine a process for high logging volume. A quarantined
process's later lines never reach the log, and the kept log holds no sign of it. A reader sees an iteration whose
events `testmanagerd` confirmed and the app has no record of. That reads as "the event never reached uniterm".

UTERM-060's M5 reads that absence to decide whether uniterm took a stalled Cmd-T event. A quarantine makes the same
absence appear for an event the app did take.

## Cause

In the run below, the app logged "Recording input" at 03:02:53.164 and `window_became_key` at 03:02:53.324. At
03:02:53.542 the log wrote `QUARANTINED DUE TO HIGH LOGGING VOLUME` for it, from `libsystem_trace.dylib`, at the fault
level, 206 ms before the first Cmd-T event. After that, none of its records reached the log.

`App/InputRecorder.swift` writes one default-level line per dequeued input event, with each pointer move included. The
fix to `scripts/collect-ui-test-log.sh`'s predicate cannot recover the lost lines. The predicate also leaves the
quarantine line out, since that line is not in the app's subsystem. Its sender is `libsystem_trace.dylib`.

## Repro

The coordinator ran the shortcut test alone for 40 iterations with recording on, on 2026-11-27: one run of 10 and one of
30. 39 iterations logged 12 records each. The 39th test start, at 03:02:52.951, ran as pid 76918. It logged 2 lines and
no event record, though `testmanagerd` confirmed events 244483 to 244496 by AX Notification.

- `/usr/bin/log show --info --debug` from 03:02:52 to 03:02:58 with `processIdentifier == 76918` has 1178 lines. One of
  them is the quarantine line above.
- The kept log's predicate selects `testmanagerd`, the runner's subsystem, and the app's `input-recording` category. It
  does not select the quarantine line.
- Pairing `testmanagerd`'s 80 Cmd-T key events with `keycode=17` records by `source_userdata` leaves exactly the 2 of
  that pid unpaired.

Expected: every event the app takes has a record, or the kept log shows that records were lost. Actual: the records are
missing and the kept log is silent.

## Fix

Each option needs a design call. None is chosen here.

- Add the quarantine line to the kept log's predicate, such as `process == 'uniterm' AND message CONTAINS
  'QUARANTINED'`, or the `libsystem_trace.dylib` sender. A reader can then see the loss. It leaves the lines lost. It
  amends UTERM-060's "What the kept log holds".
- Have `m5-summary.sh` and the flaky Rule section treat a quarantined iteration as no evidence. It needs the first
  option, or the same line from a full log. It amends the Rule section M3 wrote. It changes no code.
- Lower the recorder's volume, for example by dropping or coalescing pointer moves. Moves are most of its lines, and
  UTERM-060 chose to record them. It amends "Which events the app records", and M2's burst-cost result bears on it.
- Write the records somewhere other than the unified log, such as a file the test reads. It removes the quarantine and
  the log's redaction rules. It amends "Where the app writes the record", and it needs a path that a failed CI job
  uploads.

An option can combine the first with either of the others.

## Workarounds

Read the quarantine line directly in a run's `log show --info --debug` output for the app's pid, as the repro did. M5's
reader must do this before treating a missing record as an event that never arrived.

## Fix note

The user chose the first two options together on 2026-11-27.

- `scripts/collect-ui-test-log.sh` now selects uniterm's quarantine line, so the kept log shows the loss.
- `spec/flaky-tests.md` tells a reader to count a quarantined iteration as neither a stall nor a clean run.
- `scripts/test-ci.sh` pins the predicate with a stub `log`. The test failed before the fix.
- The lost lines stay lost. The recorder's volume is unchanged.
- `m5-summary.sh` does not exist yet. M5 must apply the same rule when it is written.
- UTERM-060's "What the kept log holds" still describes the old predicate. The proposal text is not amended here.
