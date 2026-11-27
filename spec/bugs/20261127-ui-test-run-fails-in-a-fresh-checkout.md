# A local UI test run fails at once in a checkout with no test build folder

**Status:** open
**Validation:** confirmed. Reproduced on 2026-11-27 in a new worktree.

## Observed

In a fresh worktree, `make test-app-select UI_TESTS='DataViewerUITests/testTheColumnArrowsReachTheFarEdgeOfAWideTable'`
stopped before xcodebuild ran:

```text
scripts/run-ui-tests.sh: line 41: .build/DerivedData-test/ui-test-start-time.txt: No such file or directory
make: *** [test-app-select] Error 1
```

`run-ui-tests.sh` writes the start time next to `UNITERM_UI_KEPT_LOG`, in `.build/DerivedData-test`
(`scripts/run-ui-tests.sh:39-41`). Nothing creates that folder first. `make test-app` passes the same variable, so it
should fail the same way. CI is not affected: `make test-app-shard` runs `build-for-testing` first, and that creates the
folder.

A `mkdir -p .build/DerivedData-test` works around it.

## Fix

Create the folder before writing the file, for example `mkdir -p "$(dirname "$UNITERM_UI_KEPT_LOG")"`. A regression
check needs a way to run the script's setup without the screen lock and xcodebuild, which `test-ci` does not have yet.
