# UTERM-044: Shard CI's UI Tests Across macOS Runners

**Status:** implemented
**Created:** 2026-11-21
**Updated:** 2026-11-27

## Impacts

- UTERM-045: "How the tests are divided" sets where the launcher test runs. Under today's counts the second shard
  starts with `LaunchServicesOpenUITests` and then `LauncherUITests`, so the launcher test runs third after a cold
  start, where in one `app` job it ran mid-suite. 045's test-level clean run names no job or shard, so its count reads
  the same either way.

## Summary

CI's `app` job runs every UI test on one macOS runner. This proposal splits the UI tests into shards that run side by
side on separate runners. A full run gets shorter, and so does the rerun after a flaky failure, since only the failed
shard reruns.

## Motivation

The `app` job sets the length of every CI run. In the first `app` run of #90, the job started at 04:39:46 and ended at
05:15:29. About 5 minutes went to the builds and the helper sandbox checks before the first UI test. Then 176 UI tests
ran for 1831 seconds, about 30.5 minutes, one at a time. The UI tests cannot run in parallel on one runner: they share
its one screen, and `scripts/run-ui-tests.sh` holds a lock on it. The suite has since grown on the development branch to
204 tests in 33 classes.

A flaky UI test costs a full `app` run again. `gh run rerun --failed` reruns the whole job. On 2026-11-21 the launcher
scroll flake alone cost #83, #87, and #90 one or two extra 35-minute runs each. A landing run lands its batches one
after another, so each extra run delays every batch behind it.

The other jobs set a floor. #91's `package` job ran from 05:40:31 to 05:55:50, about 15 minutes. No shard count makes a
run shorter than its longest job.

The repository is public, and the space-armada organization is on GitHub's Free plan. Standard GitHub-hosted runners,
macOS included, are free and unlimited for public repositories. The constraint is concurrency: the Free plan runs at most
5 macOS jobs at once across the organization, out of 20 jobs in total. A CI run starts 3 macOS jobs: `package`, `app`,
and `ghostty-offline`. On a pull request, `ghostty-offline` usually finds main's proof in the cache and ends within
minutes, so a run holds 2 macOS slots for most of its length.

## Design Decisions (Settled)

### Local runs keep the whole suite

Decision: `make test-app` and `make ci-app` keep running every UI test. Sharding is a property of the CI workflow.

Rationale: a local run is how a developer proves a change before pushing. A plain local run that skipped tests would be
a way to skip them by accident. "How CI selects a shard, and how a shard runs locally" below gives the shard target.

### One required check

Decision: the `ci` job stays the only required check. It passes only when every shard matches the build decision, as it
requires of the three macOS jobs today.

Rationale: branch protection names `ci`. Keeping one aggregate check means a new shard count never touches the
repository's settings.

### Every skip covers every shard

Decision: a documentation-only change skips every shard, as it skips the `app` job today. A tree that a merged PR
already passed skips every shard too. The commits "Skip main's package and app jobs when a merged PR passed the same
tree" and "Skip main's jobs only when the PR head held main's previous commit" add that skip for the `package` and `app`
jobs, and both are on `main`.

### The helper sandbox checks run once

Decision: `make test-helper-sandbox` runs in exactly one CI job per run, never split and never repeated. It runs against
the plain build, as `make ci-app` does today.

Rationale: ADR-10 makes the helper sandbox checks the proof that each helper is sandboxed and the app is not. The test
build in `DerivedData-test` signs the helpers with Xcode's test exceptions, so it cannot serve that proof.

### How the tests are divided

- **Fixed class lists.** Each shard names its classes. Easy to read. Shards drift out of balance as classes grow.
- **Xcode test plans.** One plan per shard. The scheme has no test plan today, and adding plans changes what `make
  test-app` runs, so the default plan must stay the whole suite.
- **By measured duration.** A script assigns classes from recorded durations. Balanced, but it needs a place to keep
  the durations, and a fallback when one is missing.
- **At run time, by count.** Each shard lists the test classes the build holds and takes its share, balanced by test
  count. No list to keep and no drift. Adds a split script. The largest class, `QuestionsUITests`, holds 24 of 203
  tests, so no class alone unbalances a 2- or 3-way split.

Decision: at run time, by test count, in contiguous ranges of the name order. Each shard lists the UI test classes in
the test build it just made and sorts them by name under `LC_ALL=C`. The sorted list is cut into as many runs as there
are shards. Each class goes to the shard whose range holds the midpoint of its tests in the running count, so each cut
falls at the class boundary nearest an equal share. The shard count and each shard's index come from one matrix
definition in the workflow, so every shard computes the same partition. A whole class stays in one shard.

Rationale: membership follows the build, so a new class runs in some shard with no list to keep and nothing to drift.
Each shard is a slice of the whole-suite order, so every class but a shard's first keeps the predecessor it has in `make
test-app`, which is what the flaky-test log investigates by. One changed test count moves at most one class at each cut.
On today's 204 tests in 33 classes, three shards get 69, 66, and 69 tests. A largest-first greedy split would get an
exact 68 each, but one added test would move 18 to 26 of the 33 classes between shards. A class's neighbors in CI would
then change with unrelated PRs and match no local run. Fixed class lists and test plans leave a new class needing an
entry, and test plans also change what `make test-app` runs. A split by measured duration needs a committed durations
file, and no CI path can refresh it: the workflow holds `contents: read`, a fork's PR cannot write, and results upload
only on failure. Durations fetched at run time would let a rerun compute a different partition from the first attempt
and skip a class. A split by test method gains little balance over a class split, and it breaks rerunning a class in its
original order.

Leaves undone: balance rests on test count as a proxy for time, and no per-class durations exist to confirm it. The
cuts fall at class boundaries, so a shard can run up to about half the largest class over an equal share, about 12 tests
or 2 minutes. M1
records each shard's test time, so an imbalance shows. A split weighted by committed durations is the upgrade path, and
only the weight input would change.

### Build once or build per shard

- **Build per shard.** Each shard builds the app, about 5 minutes. The shards build in parallel, so a full run loses
  nothing. Each shard stands alone.
- **Build once.** One job runs `build-for-testing` and uploads the products. Each shard downloads them and runs
  `test-without-building`. A full run gets slightly longer: the build, then a second runner's setup and download, then
  the tests. A rerun saves about 5 minutes. Uploads may drop executable bits and symlinks unless the products are
  archived first, and a rerun needs the artifact still retained.

Decision: build per shard. Each shard job makes its own test build and runs its share.

Rationale: a full run is shortest, since the shards build in parallel and nothing waits on a build job. Each shard runs
the same build-then-test path as a local run, with no artifact, archive, retention, or cross-runner image to go wrong.
Build once saves about 5 minutes per one-shard rerun. It costs a runner start, a checkout, and a download on every full
run, and it needs the products archived so bundle symlinks and signatures survive. Caching products by tree would press
on the repository's cache quota, which main's Ghostty cache depends on.

Leaves undone: each one-shard rerun repeats the roughly 5-minute test build. UTERM-045 and UTERM-046 shrink how often a
rerun happens.

### Where the helper sandbox checks run

The checks need their own plain Xcode build and a SwiftPM build. Whichever job runs them becomes longer.

- **In one shard.** That shard takes fewer test classes to balance its extra build. No new job.
- **In the `package` job.** It reuses that job's SwiftPM build, and adds a plain app build to `package`, which already
  sets the 15-minute floor.
- **In their own job.** Every shard is alike. Costs one more macOS slot per run while it runs.

Decision: in the `package` job. `ci-package` runs `test-helper-sandbox` after `test-package`, so the helper run reuses
the package test build in `.build/swiftpm`. The job gains only the plain Xcode app build.

Rationale: it is the one host that reuses a build it already has. It adds no job, no macOS slot, no result case, and no
special case in the split. Both skips already cover `package`. At two shards it would add no wall time, since `package`
grows to about 17 minutes against shards of about 21 to 23. At three shards it costs about 2 minutes per full run, and
both other placements cost more there. In one shard, the run grows by the whole helper overhead, about 2
to 3 minutes, and that shard's UI reruns repeat it. A weight for that shard in the split would be a special case that
drifts. Its own job pays a fresh SwiftPM build and a slot, and at three shards a run would start 6 macOS jobs against a
cap of 5. Every shard running the checks would reverse "The helper sandbox checks run once".

Leaves undone: a rerun of `package` after a package-test flake repeats the plain build, about 2 minutes. At three shards,
`package` is the longest job by a minute or two.

### How CI selects a shard, and how a shard runs locally

Every flag a UI run needs lives in the Makefile's `test-app` recipe: the time allowances, `-test-timeouts-enabled`, and
`-collect-test-diagnostics never`. The Makefile also says each CI job's target lets a failed job be rerun locally.

- **A shard target.** `make test-app-shard SHARD=n` runs one shard with the same flags. `make test-app` stays whole. A
  failed shard reruns locally in its original order.
- **Selection in the workflow.** The workflow calls `xcodebuild` with its own copy of the flags, and a `make test-ci`
  check fails when the copies differ. Reproducing a shard locally means copying its selection by hand.

- **The workflow computes the split.** A script picks the classes and passes them to `make test-app-select
  UI_TESTS='...'`. The run flags stay in one place, but the build and the class listing still need the Makefile's paths
  or a new target. Reproducing a shard means pasting a logged list.

Decision: a shard target. `make test-app-shard SHARD=i SHARDS=n` makes the test build, lists the classes, runs the
split, logs the selection, and runs that share through `test-app-select`'s selection path with the same flags. The
workflow calls it from a matrix job. On the tree CI built, it reruns a failed shard's share with the same command. A
pull request's run builds the merge of the PR into `main`, so on the PR's head alone the share can differ by a boundary
class. The logged `make test-app-select` line is the exact reproduction on any tree.

Rationale: the flags, the build, the listing, the split, and the run stay in one place. It keeps the Makefile's promise
that each CI job's target reruns that job locally, on the tree CI built. Selection in the workflow copies the flags and
then polices the copy. A workflow script feeding `test-app-select` still leaks the build and listing paths into the
workflow.

A matrix job reports one aggregate result to `ci`: failure when any shard fails. So `ci`'s needs and its result check
keep their `app` entry, and the shards need no entries of their own.

### How a new test class finds a shard

A class that no shard runs would silently stop running in CI.

- **A check.** `make test-ci` fails when a UI test class is in no shard, or in two. It runs on Linux in the `changes`
  job, so it parses Swift source, and its correctness rests on the parser.
- **A catch-all shard.** The last shard runs every class the others do not name, with its skip list derived from theirs.
  Correct by construction. The last shard grows out of balance over time.
- **Both.** The catch-all keeps every class running, and a check flags the imbalance.
- **Not needed.** The run-time split above leaves no list for a class to be missing from.

Decision: not needed beyond the split. A new `UITests/*.swift` file joins the UI test target through the project's
synchronized folder, with no project edit. Every shard builds the same commit, lists the same classes, and runs the
same split, so a new class lands in exactly one shard.

Rationale: the run-time split leaves no list for a class to be missing from. A check that parses Swift on Linux
duplicates what the built bundle gives, and a parser that disagrees with the compiler fails both ways. A catch-all shard
guards only against a listing that drops a class in every shard alike. With Xcode pinned and Xcode's own listing, no
such path is known. It would earn its place only if the listing came from another source.

### How many shards

The counts below assume the helper checks ride in an existing job. Their own job adds one slot.

At #90's rate of about 10.4 s per test, the 203-test suite takes about 35 minutes on one runner. Each shard also pays its
runner setup and its own test build, a few minutes.

- **Two.** A run starts 4 macOS jobs and holds 3 once `ghostty-offline` ends. A shard runs about 17.6 minutes of tests,
  so its job takes about 21 to 23 minutes. A one-shard rerun takes the same.
- **Three.** A run starts 5 macOS jobs and holds 4 once `ghostty-offline` ends, so a second run at the same time often
  queues. A shard was estimated at about 11.7 minutes of tests and a job of about 15 to 17 minutes, at or just above
  the 15-minute `package` floor. M2 measured a shard's test at 7:29 to 8:15 and its job at 7:55 to 12:09, below that
  floor. Against the two-shard estimate, the estimated full-run gain was about 6 minutes, or closer to 4 with the helper
  checks moved into `package`. That gain was an estimate that assumed `package` keeps its 15-minute floor. M2 measured
  a full run ending when `package` does, and `package` took 17:26 to 20:54.

A fix PR next to a batch PR, as on 2026-11-21, is the common case for two runs at once. A push to `main` adds a third,
unless the tested-tree skip applies to it, which it does only when the merged PR's head held `main`'s previous commit.

- **Four.** A run starts 6 macOS jobs against the cap of 5, so a lone run queues one of its own jobs. A shard job takes
  about 12 to 13 minutes, but `package` still sets the run's length, so a full run is no shorter than with three. A
  one-shard rerun is about 3 minutes shorter than with three.

Decision: three shards, as one matrix value. The figures in the options above predate the move of the helper checks into
`package`, which puts `package` at about 17 minutes. M2 measured the shard jobs at 8 to 12 minutes. Amended 2026-11-25;
see Decision Log.

Rationale: a lone run ends when `package` does, about 17 minutes, against about 22 with two shards. A one-shard rerun
takes about 8 to 12 minutes, the measured shard job length. Against the two-shard estimate of 21 to 23 minutes, that is
9 to 15 minutes shorter. The rerun's own length waits on M3. The gain over two shards is arithmetic on the test time,
whatever the shard overhead turns out to be. Each run uses about the same slot-minutes at every count, so under the
cap the count decides latency, not throughput. Two runs that start together end at about 17 and 31 to 34 minutes with
three shards, against 22 and 34 to 39 with two, so the extra queueing does not make the second run slower. Four shards
let a lone run queue against itself, and a full run is no shorter.

Leaves undone: `package` becomes the critical path, so the helper checks there cost about 2 minutes per full run. Near
395 tests, or sooner if a shard's overhead is 5 minutes rather than 3 to 4, a shard passes `package` and the count
needs revisiting. A lone run takes all 5 macOS slots at start, so any other macOS workload in the organization queues
this one. Each shard adds a first test, and the Risks section suspects first tests of cold-launch flakes. A later count
change edits `ci.yml`, which is an input to the offline Ghostty proof key, so that run's `ghostty-offline` rebuilds
once. M1's own change to `ci.yml` does the same once.

## Design Decisions (Open)

None.

## Risks

- **A test class runs in no shard** — likelihood: low, impact: high.
  Mitigation: each shard takes its classes from its own build and runs the same split, so a new class lands in exactly
  one shard. Each shard also checks that the split of its own listing puts every class in exactly one shard, and a
  `make test-ci` case proves the split on fixtures. Neither check can see two shards' listings disagree. That needs two
  builds of one commit with one pinned Xcode to list different classes, and `UITests/` has no conditional compilation.
- **Runs queue behind the concurrency cap** — likelihood: medium, impact: medium.
  Mitigation: the shard count is chosen against the cap. At three shards a lone run takes all 5 macOS slots at start,
  and two runs that start together end at about 17 and 31 to 34 minutes, no later than with two shards. A queued run is
  slower, not wrong. Another repository in the organization that runs macOS jobs would queue this one further. The
  count is one matrix value, so it changes in one line when that happens.
- **More shards mean more cold first launches** — likelihood: medium, impact: low.
  Mitigation: two logged flakes hit the first test of a run, suspected but not confirmed to be cold launches. Each shard
  has a first test. Each CI entry in the flaky-test log records whether the test ran first in its shard job, with the
  shard's logged selection, so a first-test pattern shows.
- **The class listing does not work on the CI runner** — likelihood: low, impact: medium.
  Mitigation: the split reads its classes from the built test bundle, through `xcodebuild -enumerate-tests` or an
  equivalent listing. It is not yet proved on a CI runner. The runner has a GUI session, since today's `app` job passes
  `run-ui-tests.sh`'s session check. The unknown is whether listing launches the UI test runner, and so can meet the
  same cold-launch failures before any test runs. M2 proves it first. Amended 2026-11-25; see Decision Log. If no listing
  from the build works there, the division decision reopens before the split is built, since a fallback that parses Swift
  source is a different design.
- **A Ghostty pin change rebuilds Ghostty in every build job** — likelihood: low, impact: low.
  Accepted: on a pin or patch change the setup action misses its exact cache key, so `package` and each of the three
  shards rebuild Ghostty from the fallback cache, 4 rebuilds where today there are 2. Each shard's job grows by that
  build, on those runs only.
- **Sharding changes the context of a flake under recount** — likelihood: medium, impact: low.
  Mitigation: UTERM-045's launcher recount counts clean runs of a test that, after sharding, runs third in the second
  shard, right after a cold start. One cut shift can make `LauncherUITests` that shard's first class. Its predecessor,
  `LaunchServicesOpenUITests`, stays the same as in a full run. A recount that spans the landing of this proposal
  notes the landing in the launcher entry, so a change in rate can be read against it.
- **The Free plan's limits change** — likelihood: low, impact: medium.
  Mitigation: shards are a workflow setting. Reverting the workflow returns to one `app` job.
- **Splitting moves a flake rather than fixing it** — likelihood: high, impact: low.
  Accepted: a shorter rerun is the goal. Fixing flakes is UTERM-045 and UTERM-046.

## Milestones

### M1: Shard the app job

**Status:** DONE

- Every UI test class runs in exactly one shard, and CI fails when one does not
- A shard that runs no tests, or a selection that names a class that does not exist, fails CI
- The helper sandbox checks run once per CI run, against the plain build
- `ci` fails when any shard fails, and passes only when every shard matches the build decision
- The shards run as one matrix job, and `ci` keeps one `app` entry in its needs and in its result check
- A failing shard leaves the other shards running to completion
- Each failing shard uploads its results under its own name
- A documentation-only change skips every shard, and so does an already-tested tree
- Every shard lists the classes in the same order, a `make test-ci` case proves the split covers every class exactly
  once for each shard count in use, and each shard logs its selection so a local rerun can copy it
- The shard count and every shard's index come from one matrix definition, passed as `strategy.job-index` and
  `strategy.job-total`, so no shard can split by a different count
- `make test-app-shard` fails when `SHARD` or `SHARDS` is empty, not a number, or out of range
- The class sort is pinned to `LC_ALL=C`, so a runner's or a laptop's locale cannot move a class between shards
- Each shard computes the whole partition from its own listing and fails unless every class lands in exactly one shard
  and the listing holds at least one test
- A shard fails when it ran fewer tests than its selection named, so a selected name that matches nothing cannot pass
- A local `make test-app-select` line that names a class the local tree lacks fails loudly and never passes on zero
  tests
- A class whose test midpoint lands exactly on a cut has one defined owner, and the `make test-ci` split fixture pins it
- Each shard logs a `make test-app-select UI_TESTS='...'` line that reruns its share locally
- `ci-package` runs `test-helper-sandbox` after `test-package`, never two `swift test` runs at once on one scratch path,
  and `make ci` runs the helper sandbox checks exactly once
- The comment above `ci` and the README name each CI job's local target, and `ci-app` says what it runs now that no job
  runs it
- Each shard's class list comes from the built test bundle, and a selected class not in the bundle fails CI
- Listing the classes runs under the same screen lock as the UI run
- The split script runs on the Linux `changes` runner, where its `make test-ci` fixture case runs
- CI passes `SHARD` in the same base, 0 or 1, that `make test-app-shard` documents and validates, and the logged command
  and the job's name use it
- `test-app-shard` builds into the UI test build folder, and the `make test-ci` folder check covers it beside `test-app`
- Each failing shard's results artifact is named by its shard and its run attempt, so a failed rerun does not lose them
- `spec/flaky-tests.md`'s Rule asks each CI entry to record whether the test ran first in its shard job, and the
  shard's logged selection

**As built:**

- The class listing script `scripts/list-ui-test-classes.sh` runs xcodebuild with `-enumerate-tests` writing JSON to a
  file. It reads the JSON with jq at `.values[0].children[]` to extract the `uniterm UITests` target. It filters out
  base classes with 0 tests. The script runs under the same screen lock as the UI run. The pinned Xcode 26.6 supports it.
- SHARD is 0-based everywhere. The workflow uses `strategy.job-index` and `strategy.job-total`.
- The midpoint arithmetic uses pure integer math. The formula is `(m2*SHARDS + 2*total - 1) / (2*total) - 1` where
  `m2 = 2*running + count`. An exact cut goes to the lower shard.
- The result bundle path includes the shell's PID for uniqueness.
- Test count reading uses `xcrun xcresulttool get test-results summary` on an explicit bundle. It reads the top-level
  `totalTestCount` field which includes passed, failed, skipped, and expected failures. It fails when the field is missing.
- test-app-select takes an optional EXPECTED_TESTS and fails when the bundle's total test count differs.
- test-app-shard passes its count as EXPECTED_TESTS. A shard with one missing class among many fails.
- The test-ci fixture cases cover two-shard and three-shard balanced splits. The exact-cut case has B's midpoint at 5
  landing on the first cut and going to shard 0. The fractional-share case with A 3, B 1, C 6 over 3 shards gives
  shard 0 "A", shard 1 "B", shard 2 "C". A real 33-class fixture with 206 tests splits into 10, 10, and 13 classes.
  Error cases are covered.
- The local listing proof enumerated 33 classes with 206 total tests. The split gave shards of 69, 67, and 70 tests in
  10, 10, and 13 classes. Each shard passed when run through `make test-app-shard`.
- The local test-app-select proof with BrowserRemoteUITests EXPECTED_TESTS=1 passed. With EXPECTED_TESTS=2 it failed
  with "Error: expected 2 tests, but 1 ran".
- SHARD validation fails for empty, non-numeric, and out-of-range values.
- M2 and M3 take the CI checks that need a pushed run.

### M2: The shards run on CI

**Status:** DONE

Amended 2026-11-25; see Decision Log.

- The first shard job proves on a real CI runner that the class listing works there, before the split depends on it
- The measured length of a full CI run, of `package`, and of each shard's setup, build, and test time are recorded in
  the As built block, with the suite size at which a shard's job would pass `package`

**As built:**

All clock times here are UTC. Local time in America/Los_Angeles is 8 hours earlier, so every run below ran on
2026-11-25 local time. Lengths are minutes and seconds.

- The timings use the four pull request runs 45749818748, 45752629043, 45755641410, and 45760228289. The four main push
  runs 45751929530, 45754927772, 45759466625, and 45762275495 are left out. Their jobs show `app` and `package`
  skipped as an already-tested tree, and their logs hold no "Selected N tests" line. No run uploaded an artifact, and no
  shard failed.
- The listing works on a real CI runner. In run 45749818748 each shard logged "Enumerating test classes under screen
  lock...", then its reproduce line, then "Selected N tests". Shard 0 selected 69 tests in 10 classes, from
  `BrowserRemoteUITests` through `ImageViewerUITests`. Shard 1 selected 67 tests in 10 classes, from
  `LaunchServicesOpenUITests` through `QuestionsUITests`. Shard 2 selected 70 tests in 13 classes, from
  `QuestionsWireUITests` through `WindowsUITests`.
- The three selections hold 33 distinct classes. They are contiguous in the C-sorted name order, and they match the 33
  UI test classes in the source at the pull request head. The totals add up: 69 + 67 + 70 is 206, the count M1's local
  listing found. Each listing took 18 to 22 seconds and met no cold-launch failure.
- Each shard executed exactly its selection with 0 failures, and its `EXPECTED_TESTS` check passed.
- The later pull request runs list the same classes with one change. The commit "Record the input a UI test's app
  receives in debug builds" added `InputRecordingProofTest` with 1 test. It sorts right after `ImageViewerUITests`, so
  it opens shard 1. The suite is then 34 classes and 207 tests, split 69, 68, and 70. Shards 0 and 2 keep their
  classes, and each shard again executed its selection.
- A full run took 20:04, 21:14, and 17:49 from run start to the end of `ci`. Run 45755641410's first attempt ended at
  16:45, when `ci` failed on `package`. Its second attempt took 17:26.
- `package` took 19:41, 20:54, and 17:26 in the three runs that passed first time. In run 45755641410 it took 16:25 and
  failed in `make ci-package`, then took 17:09 on the second attempt. The failure was
  `BrowserUnsentInputTests.testEditsInASubframeMarkTheTabAndOnlyThatFrameClearsIt`. It failed at
  `BrowserUnsentInputTests.swift:196`, a timeout after 19.049 seconds. The summary was "3243 tests, 1 failure". That
  test's entry in `spec/flaky-tests.md` logs the sighting. `package` was the last job to end in
  every run, and `ci` ended 7 to 9 seconds later in the three runs that passed first time.
- Shard 0 was the slowest shard job in every run. Across the four runs, its setup took 0:21 to 0:29. Its build took
  2:49 to 3:02. Its listing took 0:14 to 0:23. Its test took 7:29 to 8:15. Its whole job took 11:05 to 12:09.
- Shard 1 took 0:16 to 0:27 to set up, 1:53 to 3:25 to build, 0:09 to 0:19 to list, and 5:35 to 6:52 to test. Its job
  took 7:58 to 11:05.
- Shard 2 took 0:15 to 0:28 to set up, 1:47 to 2:58 to build, 0:12 to 0:22 to list, and 5:37 to 7:08 to test. Its job
  took 7:55 to 11:02.
- Setup runs from job start to the shard step's start. Build runs to "** TEST BUILD SUCCEEDED **". Listing runs to
  "Selected N tests". Test runs to the shard step's end, so it includes about 20 seconds of result handling after
  xcodebuild's own time. Run 45749818748's shard 0 executed for 476 seconds and its test took 495.
- The suite size at which a shard job outlasts `package`: shard 0's job minus its test time is 216 to 234 seconds, mean
  225.5. Its test rate is 6.5 to 7.2 seconds per test, mean 6.85. The mean of the four successful `package` runs is
  1127.5 seconds. Three shards each take a third of N tests, so the shard job passes `package` at N = 3 × (1127.5 −
  225.5) / 6.85, which is about 395 tests. The fastest `package` run, 1029 seconds, gives about 352. The slowest, 1254
  seconds, gives about 450. The suite holds 207 tests today.
- The Design Decisions' estimate of 234 tests assumed shard jobs of 15 to 17 minutes. The measured shard jobs take 8 to
  12 minutes, so `package` sets every run's length by a wider margin than estimated. The Design Decision now carries the
  measured figures. The decision for three shards holds.
- Shard 1 of run 45752629043 started 36 seconds after the other jobs, and shard 1 of run 45755641410 started 2:41 after
  them. Each overlapped a main push run, so the cap of 5 macOS jobs probably queued them. The other two runs started
  every job within a second.
- Partial evidence for M3: "Re-run failed jobs" on run 45755641410 reran `package` and `ci` only. The attempt 2 jobs
  list all seven jobs as attempt 2, but the three shard jobs carry attempt 1's start and end times. The failure was in
  `package`, so this shows a rerun leaves passed shards alone. It does not show a failed shard rerunning alone. M3 owns
  that, since no shard has failed on CI.

### M3: A failed shard reruns alone on CI

**Status:** DONE

Split from M2 on 2026-11-25; see Decision Log.

- Rerunning a failed job reruns only the failed shard
- The measured length of a one-shard rerun is recorded in the As built block

**As built:**

All clock times here are UTC, on 2026-11-27. Lengths are minutes and seconds.

- The proof is run 46055769038, the pull request run for "Keep the test runner's job notices off standard error". In
  attempt 1, `app (1)` failed and the other two shards passed. The one failing test was
  `LauncherUITests.testEscapeClosesTheEmptyPane`, among 68 executed. Its entry in `spec/flaky-tests.md` logs the
  sighting.
- "Re-run failed jobs" started attempt 2 at 19:42:43. Only `app (1)` and `ci` ran again. The attempt lists all seven
  jobs, but `app (0)`, `app (2)`, `package`, `ghostty-offline`, and `changes` carry attempt 1's start and end times.
- The rerun shard's job ran from 19:45:09 to 19:56:46, which is 11:37. Its setup took 0:22 and its shard step took
  11:10, build and listing included. It executed the same 68 tests with 0 failures.
- The whole rerun took 14:12, from the attempt's start to the end of `ci` at 19:56:55. The shard job started 2:26 after
  the attempt did.
- The measured 11:37 sits inside the 8 to 12 minutes the three-shard decision derived from M2's shard job lengths.
- The first failed shard on CI was `app (0)` of run 46052402044, earlier the same day. Nobody reran it. A new push
  replaced it, so it proves nothing about reruns.

## Decision Log

- 2026-11-21: Filed after a landing run that lost several hours to UI flake reruns. The user chose to pursue sharding,
  and asked whether the Free plan allows it. The repository is public, so macOS minutes are free, and the cap of 5
  concurrent macOS jobs is the constraint.
- 2026-11-21: A design review added the open questions on where the helper sandbox checks run and how a shard is
  selected and reproduced locally, and corrected the build-once option's benefit.
- 2026-11-22: Review start: 1 milestone, 4 settled decisions, 5 risks, 0 `**Live after:**` lines or row gates; no
  out-of-scope section, and "Local runs keep the whole suite" bounds the scope; reviewed as of the commit "Schedule
  UTERM-018, 040, 039, 033, 048, and 049 at the end of the queue"; an autonomous review of the 6 open questions.
- 2026-11-22: Divide the UI tests at run time by test count, from the classes in the built test bundle, with the shard
  count and index from one matrix definition. Converged in 1 pass. (autonomous)
- 2026-11-22: Build the UI tests in each shard rather than once for all shards. Converged in 1 pass. (autonomous)
- 2026-11-22: Run the helper sandbox checks in the `package` job, after the package tests, reusing their SwiftPM
  build. Converged in 2 passes. (autonomous)
- 2026-11-22: Select a shard through a `make test-app-shard SHARD=i SHARDS=n` target that a matrix job calls.
  Converged in 1 pass. (autonomous)
- 2026-11-22: A new UI test class needs no check or catch-all, since the run-time split takes classes from the build.
  Converged in 1 pass. (autonomous)
- 2026-11-22: Run three UI test shards, as one matrix value. Converged in 2 passes, after the first pass showed the
  extra queueing at three does not make a second concurrent run slower. (autonomous)
- 2026-11-22: The whole-proposal review reopened the division mechanism. Cut the name-sorted classes into contiguous
  ranges by test count, in place of a largest-first greedy split, so one changed test moves at most a boundary class
  and each class keeps its whole-suite predecessor. (autonomous)
- 2026-11-22: The shard target reproduces a share only on the tree CI built, since a PR run builds the merge with
  `main`. The logged `make test-app-select` line is the exact reproduction. (autonomous)
- 2026-11-22: Recorded the Ghostty rebuild cost of a pin change across the build jobs as an accepted low risk, reframed
  the class-listing risk, and narrowed the no-shard risk's mitigation to what each shard can see. (autonomous)
- 2026-11-22: The cold-launch risk's mitigation adds two fields to every CI entry in `spec/flaky-tests.md`'s Rule:
  whether the test ran first in its shard job, and the shard's logged selection. M1 makes the Rule change.
  (autonomous, addition)
- 2026-11-22: Coherence and risk review converged in 2 passes: one full pass and one re-check. Added the risk that
  sharding moves the launcher test next to a cold start during UTERM-045's recount. (autonomous)
- 2026-11-22: Review gate: kept all. The split by contiguous ranges of sorted class names, the matrix job, the helper
  sandbox checks in `package`, three shards, and the flaky-log fields for first-in-shard and selection all stand. No
  decision gets an ADR. Status set to accepted.
- 2026-11-22: Scheduled as UTERM-044 M1 in queue.md.
- 2026-11-25: M1's bullets that need a real CI run moved to M2: the first shard job proving the class listing works on
  CI, the rerun check, and the measured times. M1 is local work and proves the class listing locally. M2 runs on CI.
  Amended the M1 bullet "A failing shard leaves the other shards running to completion, and rerunning failed jobs reruns
  only the failed shard" to "A failing shard leaves the other shards running to completion". The rerun check moved to M2.
  The Risk "The class listing does not work on the CI runner" amended from "M1 proves it first" to "M2 proves it first".
  (run best guess)
- 2026-11-25: M2's bullet "Rerunning a failed job reruns only the failed shard" and the one-shard rerun's length moved
  to a new M3, "A failed shard reruns alone on CI". M2's third bullet read "The measured length of a full CI run, of a
  one-shard rerun, of `package`, and of each shard's setup, build, and test time are recorded in the As built block,
  with the suite size at which a shard's job would pass `package`". It now drops "of a one-shard rerun,". Eight CI runs
  followed M1 and no shard failed in any of them. This run cannot push and must not rerun a job, so it cannot make one
  fail. M3 needs a shard to fail on CI and advances only when one does. M2's As built block records the partial
  evidence from run 45755641410's second attempt. M1's As built pointer read "M2 takes the CI checks that need a pushed
  run." It now reads "M2 and M3 take the CI checks that need a pushed run." (run best guess)
- 2026-11-25: The three-shard Design Decision's estimates were amended to M2's measurements. The options bullet read "A
  shard runs about 11.7 minutes of tests, so its job takes about 15 to 17 minutes, at or just above the 15-minute
  `package` floor. That is about 6 minutes shorter than two shards, for a full run and for a rerun." It now keeps the
  estimates as estimates and gives M2's measured test time of 7:29 to 8:15 and job time of 7:55 to 12:09, below the
  floor. It labels the 6 minute and 4 minute full-run gains as estimates against the two-shard estimate. A measured
  full run ends when `package` does, and `package` took 17:26 to 20:54. The Rationale read "A one-shard rerun
  takes about 15 to 16 minutes, about 6 minutes shorter than with two." It now reads about 8 to 12 minutes, the measured
  shard job length, and 9 to 15 minutes shorter than the two-shard estimate of 21 to 23 minutes. The rerun figure is
  derived from the shard job length and compared against an estimate. The rerun's own length waits on M3. "Near 234
  tests" under Leaves undone now reads "Near 395 tests". M2 measured the crossover at about 395 tests, with a range of
  352 to 450. The decision itself, three shards, stands. (run best guess)
- 2026-11-27: M3 finished from run 46055769038, whose failed `app (1)` shard reran alone in 11:37. Every milestone is
  finished, so the status is implemented. The user chose to close M3 from that run.

## References

- ADR-10: App unsandboxed, helpers sandboxed
- `spec/flaky-tests.md`
- [GitHub Actions limits](https://docs.github.com/en/actions/reference/limits)
