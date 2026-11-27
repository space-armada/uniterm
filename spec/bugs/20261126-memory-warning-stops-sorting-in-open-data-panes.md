# A memory-pressure warning stops sorting in every data pane already open

**Status:** fixed 2026-11-26
**Fixed:** 2026-11-26
**Estimate:** small; no open design decisions. Re-checked 2026-11-26 against the code, UTERM-009, and UTERM-062. The fix touches `TableBudget.swift` (a lease reservation that skips the epoch check, for sorts) and `TableQuery.swift` (`SortMemory` uses it), plus one regression test in `TableQueryTests.swift` or `TableBudgetTests.swift`. UTERM-009 and the budget's doc comment limit a warning to loads running at that moment. UTERM-062 M2 is not started and keeps the same rule for a tab loaded before a warning, so the interim fix does not conflict with it.

## Observed

Found by a design critique of UTERM-062 on 2026-11-26. After the system sends one memory-pressure warning, every data
viewer pane that was already open skips every sort until it loads another file. The notice it posts blames the row
count, "There is not enough memory to sort this many rows", not the memory warning.

## Cause

- A lease records the budget's epoch when it is made (`Packages/UnitermKit/Sources/TableData/TableBudget.swift`,
  `makeLease`, about lines 53-61).
- `memoryPressureWarning` bumps the epoch (about line 64). From then on, every `reserve` on an older lease returns
  `.memoryPressure`, since its epoch no longer matches (about line 70).
- A sort reserves its key memory through the same lease (`TableQuery.swift`, `SortMemory`, about lines 54-61). It gets
  `.memoryPressure`, treats that as no memory, and skips the sort (about lines 155-156).
- The lease is only remade when the pane loads another file (`TableSession.swift`, about line 351).

The budget's doc comment and UTERM-009 say a warning "ends every load running at that moment". It also ends every later
sort in panes already open, which neither says.

## Repro

Not run. A package test would open a table, call `memoryPressureWarning()` on its budget, and then sort. The sort is
skipped where it should run.

## Fix

Gate only loads on the epoch. A sort's reservation checks the budget's limit and floor, not the epoch, so a warning
ends running loads and nothing else. UTERM-062 M2 replaces the event model with a pressure state, and its check that a
tab loaded before a warning sorts and filters again covers this too.

## Fix note

`Lease.reserveForWork` checks the limit and floor but not the epoch, and `SortMemory` uses it. `reserve` is unchanged, so a
warning still ends loads. A sort in a pane already open now runs after a warning. Files: `TableBudget.swift`,
`TableQuery.swift`. Regression test: `TableQueryTests.testASortStillRunsAfterAMemoryWarning`.
