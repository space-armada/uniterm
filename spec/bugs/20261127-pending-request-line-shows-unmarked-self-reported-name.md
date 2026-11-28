# A "Pending request:" line can show a program's self-reported name with no unverified marker

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27
**Estimate:** small; no open design decisions

## Observed

The bar's "Pending request:" line is posted from the `uniterm` source. When uniterm cannot find the requesting
program's executable path, the line shows the name the program reported for itself. It carries no "(unverified
script)" marker. A program can then put a name of its choosing on a line under uniterm's own label.

## Cause

`PendingRequestsIndicator.waitingItems` builds each line as `"\(program ?? request.name), PID \(request.pid), asks for
a pane."` (`Packages/UnitermKit/Sources/WindowKit/PendingRequestsIndicator.swift:77-81`). `refresh` posts it from the
`uniterm` source (`:39-44`). `program` comes from `ProcessInspection.executablePath(of:)`. When that returns nil, the
line falls back to `request.name`. That is the session's name (`ScriptHost/ScriptHost.swift:1136`), which a script
can set from its own begin message.

The Questions header marks a self-reported name as "(unverified script)" (`ScriptHost/ScriptQuestions.swift:424`).
This line does not.

## Repro

Have a program whose executable path the lookup cannot read connect with a chosen begin name and ask for a pane.

- Expected: the line names the program by its verified path, or marks the name "(unverified script)".
- Actual, by trace: the line shows the chosen name, unmarked.

## Fix

Mark the fallback name "(unverified script)", as the Questions header does.

## Fix note

Triaged and fixed on 2026-11-27.

- The same fallback also fed the Pending Requests panel's program column and the Allow-for-pane alert. All three now
  take their text from one `programLabel` on the request. A request with no executable path shows its self-reported
  name followed by "(unverified script)".
- The regression test is `PendingRequestsTests.testARequestWithNoExecutablePathMarksItsSelfReportedNameUnverified`. It
  failed before the fix on the bar line and passes after it.
- The test pins the bar line only. The panel column and the alert use the same property but have no test of their own.
- Files changed: `ScriptHost.swift`, `PendingRequestsIndicator.swift`, `PendingRequestsWindowController.swift`, and
  `PendingRequestsTests.swift`.
