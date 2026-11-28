#!/usr/bin/env bash
set -euo pipefail

# Real Git history exercises classification and the final status gate, not GitHub's scheduler.
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git init --quiet "$repo"
git -C "$repo" config user.name "CI fixture"
git -C "$repo" config user.email "ci-fixture@example.invalid"
git -C "$repo" config commit.gpgsign false
mkdir -p "$repo/spec/proposals" "$repo/App" "$repo/Licenses"

commit_fixture() {
  local path
  for path in "$@"; do
    if [[ -e "$repo/$path" ]]; then
      git -C "$repo" add -- "$path" || return
    fi
  done
  git -C "$repo" -c core.hooksPath=/dev/null commit --quiet -m "Fixture" -- "$@" || return
  git -C "$repo" rev-parse HEAD
}

expect_changes() {
  local name="$1" event="$2" base="$3" head="$4" expected="$5" actual
  : >"$scratch/output"
  (
    cd "$repo"
    GITHUB_EVENT_NAME="$event" BASE_SHA="$base" HEAD_SHA="$head" \
      GITHUB_OUTPUT="$scratch/output" bash "$root/scripts/ci-changes.sh" >"$scratch/log" 2>&1
  )
  IFS= read -r actual <"$scratch/output"
  if [[ "$actual" != "build_required=$expected" ]]; then
    echo "FAIL: $name: expected $expected, got $actual" >&2
    cat "$scratch/log" >&2
    exit 1
  fi
  echo "PASS: $name"
}

expect_result() {
  local name="$1" changes="$2" required="$3" package="$4" app="$5" ghostty="$6" expected="$7" actual
  local tested="${8:-}"
  if CHANGES_RESULT="$changes" BUILD_REQUIRED="$required" TESTED="$tested" PACKAGE_RESULT="$package" \
    APP_RESULT="$app" GHOSTTY_OFFLINE_RESULT="$ghostty" \
    bash "$root/scripts/ci-result.sh" >"$scratch/log" 2>&1; then
    actual=0
  else
    actual=$?
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $name: expected exit $expected, got $actual" >&2
    cat "$scratch/log" >&2
    exit 1
  fi
  echo "PASS: $name"
}

printf 'Initial\n' >"$repo/README.md"
printf 'Initial\n' >"$repo/spec/proposals/plan.md"
printf 'Initial\n' >"$repo/App/Main.swift"
printf 'Initial\n' >"$repo/Licenses/LICENSE.md"
initial="$(commit_fixture README.md spec/proposals/plan.md App/Main.swift Licenses/LICENSE.md)"

printf 'Root docs\n' >>"$repo/README.md"
root_docs="$(commit_fixture README.md)"
expect_changes "root Markdown skips on push" push "$initial" "$root_docs" false
expect_changes "root Markdown skips on PR" pull_request "$initial" "$root_docs" false

printf 'Proposal\n' >>"$repo/spec/proposals/plan.md"
spec_docs="$(commit_fixture spec/proposals/plan.md)"
expect_changes "nested spec Markdown skips" pull_request "$root_docs" "$spec_docs" false

printf 'Code\n' >>"$repo/App/Main.swift"
code="$(commit_fixture App/Main.swift)"
expect_changes "code builds" push "$spec_docs" "$code" true

printf 'Later docs\n' >>"$repo/README.md"
later_docs="$(commit_fixture README.md)"
expect_changes "PR includes earlier code commits" pull_request "$initial" "$later_docs" true
expect_changes "push uses before rather than PR history" push "$code" "$later_docs" false

printf 'Mixed\n' >>"$repo/README.md"
printf 'Mixed\n' >>"$repo/App/Main.swift"
mixed="$(commit_fixture README.md App/Main.swift)"
expect_changes "mixed changes build" push "$later_docs" "$mixed" true

printf 'License\n' >>"$repo/Licenses/LICENSE.md"
license="$(commit_fixture Licenses/LICENSE.md)"
expect_changes "bundled Markdown builds" push "$mixed" "$license" true

git -C "$repo" mv App/Main.swift Notes.md
renamed="$(commit_fixture App/Main.swift Notes.md)"
expect_changes "code renamed to Markdown builds" push "$license" "$renamed" true

git -C "$repo" rm --quiet README.md
deleted_docs="$(commit_fixture README.md)"
expect_changes "deleted documentation skips" push "$renamed" "$deleted_docs" false

git -C "$repo" mv Notes.md App/New.swift
renamed_back="$(commit_fixture Notes.md App/New.swift)"
expect_changes "Markdown renamed to code builds" push "$deleted_docs" "$renamed_back" true

printf 'Workflow\n' >"$repo/spec/workflow.yml"
non_markdown="$(commit_fixture spec/workflow.yml)"
expect_changes "non-Markdown spec files build" push "$renamed_back" "$non_markdown" true

odd_path=$'spec/proposals/line\nbreak.md'
printf 'Odd name\n' >"$repo/$odd_path"
odd_doc="$(commit_fixture "$odd_path")"
expect_changes "newline in documentation path is safe" push "$non_markdown" "$odd_doc" false

# A PR compares against the merge base, not changes made only on its base branch.
git -C "$repo" checkout --quiet --detach "$non_markdown"
printf 'Base-only code\n' >>"$repo/App/New.swift"
advanced_base="$(commit_fixture App/New.swift)"
expect_changes "PR uses merge-base comparison" pull_request "$advanced_base" "$odd_doc" false

expect_changes "manual dispatch always builds" workflow_dispatch "$initial" "$root_docs" true
expect_changes "unknown events build" schedule "$initial" "$root_docs" true
expect_changes "initial push builds" push 0000000000000000000000000000000000000000 "$root_docs" true
expect_changes "missing revisions build" push "" "$root_docs" true
expect_changes "unavailable history builds" push aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$root_docs" true
expect_changes "empty diff builds conservatively" push "$root_docs" "$root_docs" true

expect_result "intentional docs skip passes" success false skipped skipped skipped 0
expect_result "successful full build passes" success true success success success 0
expect_result "detector failure fails" failure false skipped skipped skipped 1
expect_result "package failure fails" success true failure success success 1
expect_result "app failure fails" success true success failure success 1
expect_result "Ghostty offline failure fails" success true success success failure 1
expect_result "cancelled job fails" success true success cancelled success 1
expect_result "unexpected skipped job fails" success true success success skipped 1
expect_result "missing job result fails" success true success "" success 1
expect_result "missing decision fails" success "" skipped skipped skipped 1
expect_result "malformed decision fails" success maybe skipped skipped skipped 1
expect_result "unexpected work on docs path fails" success false skipped failure skipped 1
expect_result "unexpected success on docs path fails" success false success skipped skipped 1
expect_result "a tested tree passes with only the offline check" success true skipped skipped success 0 true
expect_result "a tested tree still needs the offline check" success true skipped skipped failure 1 true
expect_result "a tested tree with a skipped offline check fails" success true skipped skipped skipped 1 true
expect_result "a tested tree that ran the app job fails" success true skipped success success 1 true
expect_result "an untested tree needs every job" success true skipped skipped success 1 false
expect_result "a docs skip cannot carry a tested tree" success false skipped skipped skipped 1 true
expect_result "a malformed tested answer fails" success true skipped skipped success 1 maybe

# GitHub's API is the one outside input to the tested-tree check. The fake answers with JSON shaped
# like GitHub's and applies the script's own --jq filter with jq, so the filters are proved too.
fake_gh="$scratch/fake-gh"
cat >"$fake_gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api && "$3" == --jq ]] || exit 2
case "$2" in
  */commits/*/pulls) body="$FAKE_PULLS" ;;
  */git/commits/*) body="$FAKE_COMMIT" ;;
  */check-runs\?check_name=ci\&filter=latest) body="$FAKE_CHECKS" ;;
  *) exit 2 ;;
esac
[[ "$body" != fail ]] || exit 1
printf '%s' "$body" | jq -r "$4"
FAKE
chmod +x "$fake_gh"

# A PR branch off main, and GitHub's merge commit for it. The head holds main's previous commit,
# so the merge keeps the head's tree.
git -C "$repo" checkout --quiet --detach "$odd_doc"
printf 'PR\n' >"$repo/App/PR.swift"
pr_head="$(commit_fixture App/PR.swift)"
merged="$(git -C "$repo" commit-tree "$pr_head^{tree}" -p "$odd_doc" -p "$pr_head" -m Merge)"

# Main gains a change and reverts it while the PR is open. The merge's tree still equals the head's,
# but a PR run made between the two tested a merge that held the change.
git -C "$repo" checkout --quiet --detach "$odd_doc"
printf 'Gone\n' >"$repo/App/Gone.swift"
commit_fixture App/Gone.swift >/dev/null
git -C "$repo" rm --quiet App/Gone.swift
reverted="$(commit_fixture App/Gone.swift)"
remerged="$(git -C "$repo" commit-tree "$pr_head^{tree}" -p "$reverted" -p "$pr_head" -m Merge)"

merge_tree="$(git -C "$repo" rev-parse "$pr_head^{tree}")"
other_tree="$(git -C "$repo" rev-parse "$license^{tree}")"

pulls_json() {
  local merge_sha="$1" merged_at="${2:-2026-11-21T00:00:00Z}"
  printf '[{"number":82,"merged_at":"%s","merge_commit_sha":"%s","head":{"sha":"%s"}}]' \
    "$merged_at" "$merge_sha" "$pr_head"
}

checks_json() {
  local conclusions="$1" runs="" conclusion
  for conclusion in $conclusions; do
    runs+="${runs:+,}{\"name\":\"ci\",\"conclusion\":\"$conclusion\"}"
  done
  printf '{"total_count":%s,"check_runs":[%s]}' "$(wc -w <<<"$conclusions")" "$runs"
}

expect_tested() {
  local name="$1" event="$2" head="$3" pulls="$4" commit="$5" checks="$6" expected="$7" actual
  : >"$scratch/output"
  (
    cd "$repo"
    GITHUB_EVENT_NAME="$event" HEAD_SHA="$head" GITHUB_REPOSITORY=example/repo \
      CI_TESTED_TREE_GH="$fake_gh" FAKE_PULLS="$pulls" FAKE_COMMIT="$commit" FAKE_CHECKS="$checks" \
      GITHUB_OUTPUT="$scratch/output" bash "$root/scripts/ci-tested-tree.sh" >"$scratch/log" 2>&1
  )
  IFS= read -r actual <"$scratch/output"
  if [[ "$actual" != "tested=$expected" ]]; then
    echo "FAIL: $name: expected $expected, got $actual" >&2
    cat "$scratch/log" >&2
    exit 1
  fi
  echo "PASS: $name"
}

same_tree="{\"sha\":\"$pr_head\",\"tree\":{\"sha\":\"$merge_tree\"}}"
passed="$(checks_json success)"

expect_tested "a merge of a passing PR's exact tree is tested" push "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$passed" true
expect_tested "a PR head with another tree is untested" push "$merged" \
  "$(pulls_json "$merged")" "{\"tree\":{\"sha\":\"$other_tree\"}}" "$passed" false
expect_tested "a failed ci check is untested" push "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$(checks_json failure)" false
expect_tested "a ci check still running is untested" push "$merged" \
  "$(pulls_json "$merged")" "$same_tree" '{"total_count":1,"check_runs":[{"name":"ci","conclusion":null}]}' false
expect_tested "no ci check is untested" push "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$(checks_json "")" false
expect_tested "two ci checks are untested" push "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$(checks_json "success success")" false
expect_tested "an unmerged PR is untested" push "$merged" \
  "$(pulls_json "$merged" null | sed 's/"null"/null/')" "$same_tree" "$passed" false
expect_tested "a PR that only contains the commit is untested" push "$merged" \
  "$(pulls_json "$license")" "$same_tree" "$passed" false
expect_tested "two merged PRs naming the commit are untested" push "$merged" \
  "[$(pulls_json "$merged" | tr -d '[]'),$(pulls_json "$merged" | tr -d '[]')]" "$same_tree" "$passed" false
expect_tested "an unreadable PR list is untested" push "$merged" fail "$same_tree" "$passed" false
expect_tested "an unreadable PR head is untested" push "$merged" "$(pulls_json "$merged")" fail "$passed" false
expect_tested "an unreadable ci check is untested" push "$merged" "$(pulls_json "$merged")" "$same_tree" fail false
expect_tested "a PR event is never tested" pull_request "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$passed" false
expect_tested "a manual run is never tested" workflow_dispatch "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$passed" false
expect_tested "a malformed head is untested" push "not-a-sha" \
  "$(pulls_json "$merged")" "$same_tree" "$passed" false
expect_tested "a merge after main changed and changed back is untested" push "$remerged" \
  "$(pulls_json "$remerged")" "$same_tree" "$passed" false
expect_tested "a squash merge whose head is not in the clone is untested" push "$merged" \
  "$(pulls_json "$merged" | sed "s/$pr_head/2222222222222222222222222222222222222222/")" "$same_tree" "$passed" false
expect_tested "a head missing locally is untested" push aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$(pulls_json aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" "$same_tree" "$passed" false

# The offline job looks up main's Ghostty cache by the setup action's key. A key that drifted would
# miss on every tested push, and each one would rebuild Ghostty.
ghostty_keys() {
  grep -h -o 'key: ghostty-\${{ runner.arch }}-.*' "$@" | sort -u
}
setup_key="$(ghostty_keys "$root/.github/actions/macos-setup/action.yml")"
workflow_key="$(ghostty_keys "$root/.github/workflows/ci.yml")"
if [[ -z "$setup_key" || "$setup_key" != "$workflow_key" ]]; then
  echo "FAIL: the workflow's Ghostty cache key '$workflow_key' differs from the setup action's '$setup_key'" >&2
  exit 1
fi
echo "PASS: the offline job looks up the setup action's Ghostty cache key"

# The proven key must change with every input of the offline rebuild, and must never repeat on a
# runner that reports no image version.
proof="$scratch/proof"
proof_inputs=(ghostty.pin scripts/build-ghostty.sh scripts/ghostty-offline-check.sh
  scripts/ghostty-proof-key.sh .github/workflows/ci.yml .github/actions/macos-setup/action.yml)
for path in "${proof_inputs[@]}"; do
  mkdir -p "$proof/$(dirname "$path")"
  cp "$root/$path" "$proof/$path"
done

proof_key() {
  env -u GITHUB_OUTPUT GHOSTTY_PROOF_ROOT="$proof" RUNNER_ARCH=ARM64 "$@" \
    bash "$root/scripts/ghostty-proof-key.sh" | sed -n 's/^key=//p'
}

expect_keys() {
  local name="$1" relation="$2" first="$3" second="$4"
  if [[ -z "$first" || -z "$second" ]]; then
    echo "FAIL: $name: a key was empty" >&2
    exit 1
  fi
  if [[ "$relation" == same && "$first" != "$second" ]] ||
    [[ "$relation" == different && "$first" == "$second" ]]; then
    echo "FAIL: $name: expected $relation keys, got $first and $second" >&2
    exit 1
  fi
  echo "PASS: $name"
}

image=(ImageOS=macos26 ImageVersion=20261101.1)
baseline="$(proof_key "${image[@]}")"

expect_keys "same inputs and image give the same key" same "$baseline" "$(proof_key "${image[@]}")"
expect_keys "a new runner image changes the key" different "$baseline" \
  "$(proof_key ImageOS=macos26 ImageVersion=20261108.1)"

for path in "${proof_inputs[@]}"; do
  cp "$proof/$path" "$scratch/saved"
  printf '\n# changed\n' >>"$proof/$path"
  expect_keys "a change to $path changes the key" different "$baseline" "$(proof_key "${image[@]}")"
  cp "$scratch/saved" "$proof/$path"
done

expect_keys "restored inputs give the first key again" same "$baseline" "$(proof_key "${image[@]}")"

unknown_first="$(proof_key ImageOS= ImageVersion= GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1)"
unknown_second="$(proof_key ImageOS= ImageVersion= GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1)"
expect_keys "no image version never repeats a key" different "$unknown_first" "$unknown_second"

rm "$proof/ghostty.pin"
if proof_key "${image[@]}" >/dev/null 2>&1 && [[ -n "$(proof_key "${image[@]}" 2>/dev/null)" ]]; then
  echo "FAIL: a missing input still produced a key" >&2
  exit 1
fi
echo "PASS: a missing input produces no key"

# The swift test watchdog samples with macOS's `sample`, so it is proved only on macOS. The changes
# job runs these checks on Linux, and the package job runs them again on macOS.
if [[ "$(uname -s)" != Darwin ]]; then
  echo "SKIP: the package test time limit runs only on macOS"
  exit 0
fi

# The watchdog runs fake test commands. A copy of `sleep` named xctest stands in for the test
# process, so the abort path runs against a real child without building any tests. macOS kills a
# copied system binary at launch, so the copy is signed again, ad hoc.
watch_dir="$scratch/watch"
mkdir -p "$watch_dir"
cp /bin/sleep "$watch_dir/xctest"
codesign --force --sign - "$watch_dir/xctest" 2>/dev/null

cat >"$watch_dir/passing" <<'FAKE'
#!/usr/bin/env bash
echo "Test Case '-[Suite testOne]' started."
echo "Test Case '-[Suite testOne]' passed (0.001 seconds)."
echo "after the tests"
FAKE

cat >"$watch_dir/failing" <<'FAKE'
#!/usr/bin/env bash
echo "Test Case '-[Suite testOne]' started."
echo "Test Case '-[Suite testOne]' failed (0.001 seconds)."
exit 3
FAKE

cat >"$watch_dir/stuck" <<FAKE
#!/usr/bin/env bash
echo "Test Case '-[Suite testStuck]' started."
"$watch_dir/xctest" 60
FAKE

cat >"$watch_dir/slow-run" <<'FAKE'
#!/usr/bin/env bash
for name in testFirst testSecond testThird; do
  echo "Test Case '-[Suite $name]' started."
  sleep 1.5
  echo "Test Case '-[Suite $name]' passed (1.500 seconds)."
done
FAKE

chmod +x "$watch_dir/passing" "$watch_dir/failing" "$watch_dir/stuck" "$watch_dir/slow-run"

run_watch() {
  local limit="$1" command="$2"
  RUN_SWIFT_TESTS_POLL=1 RUN_SWIFT_TESTS_GRACE=5 \
    bash "$root/scripts/run-swift-tests.sh" "$limit" "$watch_dir/$command" \
    >"$scratch/watch-out" 2>"$scratch/watch-err"
}

expect_watch_status() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $name: expected exit $expected, got $actual" >&2
    cat "$scratch/watch-out" "$scratch/watch-err" >&2
    exit 1
  fi
}

expect_watch_text() {
  local name="$1" file="$2" text="$3"
  if ! grep -qF -- "$text" "$scratch/$file"; then
    echo "FAIL: $name: $file lacks: $text" >&2
    cat "$scratch/watch-out" "$scratch/watch-err" >&2
    exit 1
  fi
}

status=0
run_watch 30 passing || status=$?
expect_watch_status "a passing run passes its status through" 0 "$status"
expect_watch_text "a passing run passes its output through" watch-out "after the tests"
if [[ -s "$scratch/watch-err" ]]; then
  echo "FAIL: a passing run wrote to standard error" >&2
  cat "$scratch/watch-err" >&2
  exit 1
fi
echo "PASS: a passing run is passed through untouched"

# CI's runners have only macOS's bash 3.2. When it reaps the stopped watcher before the script waits
# for it, it prints a "Terminated" notice on the script's standard error. That depends on timing, so
# the run is repeated under load until a regression would almost surely show.
quiet_failures=0
for batch in 1 2 3 4 5 6 7 8; do
  for slot in 1 2 3 4 5 6 7 8; do
    (
      RUN_SWIFT_TESTS_POLL=1 RUN_SWIFT_TESTS_GRACE=5 \
        /bin/bash "$root/scripts/run-swift-tests.sh" 30 "$watch_dir/passing" \
        >/dev/null 2>"$scratch/quiet-err-$slot" || true
    ) &
  done
  wait

  for slot in 1 2 3 4 5 6 7 8; do
    if [[ -s "$scratch/quiet-err-$slot" ]]; then
      quiet_failures=$((quiet_failures + 1))
      cp "$scratch/quiet-err-$slot" "$scratch/quiet-err"
    fi
  done
done
if ((quiet_failures > 0)); then
  echo "FAIL: $quiet_failures of 64 passing runs under /bin/bash wrote to standard error" >&2
  cat "$scratch/quiet-err" >&2
  exit 1
fi
echo "PASS: passing runs under /bin/bash stay quiet"

# A UI test build signs the helpers with Xcode's test exceptions, and a later plain build in the same
# folder keeps the app's copies of them. So the UI tests must never build where the helper sandbox
# probes and `make run` read the app.
derived_data_paths() {
  local output status=0
  output=$(make -C "$root" -n $1) || status=$?
  if [[ $status -ne 0 ]]; then
    echo "Error: make -n $1 failed with status $status" >&2
    return $status
  fi
  echo "$output" | grep -o -- '-derivedDataPath [^ ]*' | sort -u
}

test_build_paths="$(derived_data_paths test-app)"
for target in build test-helper-sandbox; do
  if [[ -z "$test_build_paths" ]] || [[ "$(derived_data_paths "$target")" == "$test_build_paths" ]]; then
    echo "FAIL: make test-app builds into the same folder as make $target: $test_build_paths" >&2
    exit 1
  fi
done
echo "PASS: the UI tests build apart from the app the helper sandbox probes"

# test-app-shard uses TEST_DERIVED_DATA like test-app.
shard_build_paths="$(derived_data_paths "test-app-shard SHARD=0 SHARDS=1")"
if [[ -z "$shard_build_paths" ]] || [[ "$shard_build_paths" != "$test_build_paths" ]]; then
  echo "FAIL: make test-app-shard builds into a different folder than make test-app" >&2
  echo "  test-app: $test_build_paths" >&2
  echo "  test-app-shard: $shard_build_paths" >&2
  exit 1
fi
for target in build test-helper-sandbox; do
  if [[ "$shard_build_paths" == "$(derived_data_paths "$target")" ]]; then
    echo "FAIL: make test-app-shard builds into the same folder as make $target: $shard_build_paths" >&2
    exit 1
  fi
done
echo "PASS: test-app-shard builds into the same folder as test-app"

status=0
run_watch 30 failing || status=$?
expect_watch_status "a failing run passes its status through" 3 "$status"
echo "PASS: a failing run keeps its status"

status=0
started_at="$(date +%s)"
run_watch 2 stuck || status=$?
elapsed=$(($(date +%s) - started_at))
if [[ "$status" == 0 ]]; then
  echo "FAIL: a stuck test passed" >&2
  exit 1
fi
expect_watch_text "a stuck test is named" watch-err "-[Suite testStuck] has run for"
expect_watch_text "a stuck test process is sampled" watch-err "sampling test process"
expect_watch_text "a stuck test process is aborted" watch-err "aborting test process"
if ((elapsed > 40)); then
  echo "FAIL: a stuck test took $elapsed s to end" >&2
  exit 1
fi
echo "PASS: a stuck test is named, sampled, and aborted"

status=0
run_watch 2 slow-run || status=$?
expect_watch_status "a run longer than the limit, of short tests, passes" 0 "$status"
expect_watch_text "a run longer than the limit keeps every test" watch-out "-[Suite testThird]' passed"
echo "PASS: the limit applies to each test, not to the run"

# The UI test split divides classes by test count into contiguous ranges of the name-sorted list.
# A class whose test midpoint lands exactly on a cut has one defined owner. This checks every shard
# and verifies the union covers all classes exactly once.
expect_split() {
  local name="$1" total_shards="$2" fixture="$3"
  shift 3
  local expected_shards=("$@")

  local list="$scratch/split-list.txt"
  local count_file="$scratch/split-count.txt"
  printf '%s\n' "$fixture" >"$list"

  local all_classes="$(echo "$fixture" | awk '{print $1}' | LC_ALL=C sort)"
  local union=""

  for ((shard=0; shard<total_shards; shard++)); do
    local stdout
    stdout="$("$root/scripts/shard-ui-tests.sh" "$shard" "$total_shards" "$list" "$count_file")" || {
      echo "FAIL: $name: shard $shard failed" >&2
      exit 1
    }
    local actual="$(echo "$stdout" | tr '\n' ' ' | sed 's/ *$//')"
    local expected="${expected_shards[$shard]}"
    if [[ "$actual" != "$expected" ]]; then
      echo "FAIL: $name: shard $shard expected '$expected', got '$actual'" >&2
      exit 1
    fi
    union="$union $actual"
  done

  local union_sorted="$(echo "$union" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort)"
  if [[ "$union_sorted" != "$all_classes" ]]; then
    echo "FAIL: $name: union does not match all classes" >&2
    echo "  all classes: $all_classes" >&2
    echo "  union: $union_sorted" >&2
    exit 1
  fi

  echo "PASS: $name"
}

expect_split_error() {
  local name="$1" total_shards="$2" fixture="$3" error_text="$4"
  local list="$scratch/split-list.txt"
  local count_file="$scratch/split-count.txt"
  printf '%s\n' "$fixture" >"$list"
  local output
  if output="$("$root/scripts/shard-ui-tests.sh" 0 "$total_shards" "$list" "$count_file" 2>&1)"; then
    echo "FAIL: $name: shard-ui-tests.sh passed when it should have failed" >&2
    exit 1
  fi
  if ! echo "$output" | grep -qF "$error_text"; then
    echo "FAIL: $name: error lacks: $error_text" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "PASS: $name"
}

# Two shards, 10 tests in 3 classes. Each shard gets 5 tests. B's midpoint at 3.5 is before the cut
# at 5, so B goes to shard 0 with A.
expect_split "two shards balanced" 2 "A 2
B 3
C 5" "A B" "C"

# Three shards, 15 tests in 5 classes. Each shard gets 5 tests. B's midpoint at 5 lands exactly on
# the first cut, so B goes to shard 0.
expect_split "three shards with exact cut" 3 "A 3
B 4
C 3
D 2
E 3" "A B" "C" "D E"

# Three shards with fractional share. Total 10, each shard gets 3.33. A's midpoint 1.5 < 3.33 goes
# to shard 0. B's midpoint 3.5 > 3.33 and < 6.67 goes to shard 1. C's midpoint 7 > 6.67 goes to
# shard 2.
expect_split "three shards fractional" 3 "A 3
B 1
C 6" "A" "B" "C"

# Real 33-class listing, 206 tests over 3 shards. Shard 0 gets 69 tests (10 classes), shard 1 gets
# 67 tests (10 classes), shard 2 gets 70 tests (13 classes).
expect_split "real 33-class listing" 3 "BrowserRemoteUITests 1
BrowserUITests 12
CommandPaletteUITests 13
ControllerConsentUITests 9
ControllerRunUITests 1
DataViewerUITests 10
DockedPaletteUITests 7
ExecPaneUITests 2
FormLayoutUITests 1
ImageViewerUITests 13
LaunchServicesOpenUITests 2
LauncherUITests 7
LayoutUITests 7
MapViewerUITests 12
OpenPanelUITests 1
PaneControlUITests 1
PaneTreeUITests 10
PendingRequestsUITests 2
PresentationUITests 1
QuestionsUITests 24
QuestionsWireUITests 3
ReplCapabilityUITests 1
ReplUITests 7
ScriptOpenUITests 2
ScriptRunUITests 2
ShortcutOwnershipUITests 7
StatusBarUITests 5
TabsUITests 6
TerminalLinkUITests 2
TerminalUITests 11
TextViewerUITests 14
WindowChromeUITests 4
WindowsUITests 6" \
"BrowserRemoteUITests BrowserUITests CommandPaletteUITests ControllerConsentUITests ControllerRunUITests DataViewerUITests DockedPaletteUITests ExecPaneUITests FormLayoutUITests ImageViewerUITests" \
"LaunchServicesOpenUITests LauncherUITests LayoutUITests MapViewerUITests OpenPanelUITests PaneControlUITests PaneTreeUITests PendingRequestsUITests PresentationUITests QuestionsUITests" \
"QuestionsWireUITests ReplCapabilityUITests ReplUITests ScriptOpenUITests ScriptRunUITests ShortcutOwnershipUITests StatusBarUITests TabsUITests TerminalLinkUITests TerminalUITests TextViewerUITests WindowChromeUITests WindowsUITests"

# One shard gets everything.
expect_split "one shard" 1 "A 2
B 3
C 5" "A B C"

# Empty listing fails.
expect_split_error "empty listing fails" 1 "" "no classes in listing"

# Zero tests fails.
expect_split_error "zero tests fails" 1 "A 0" "test count must be a positive integer"

# Invalid format fails.
expect_split_error "invalid format fails" 1 "A" "invalid line format"

# The follow-up step exists for a test step that its timeout stopped before it collected the kept
# log. A shard whose tests failed already collected one, and collecting again would replace it with
# a log whose window ends later. The step's script runs against a fake collector that records its
# calls, so the test proves what the workflow's own script does, not GitHub's scheduling of it.
followup_script() {
  awk '
    /- name: Collect kept log if test step did not complete/ { found = 1; next }
    found && /^        run: \|$/ { body = 1; next }
    body && /^$/ { print; next }
    body && /^          / { sub(/^          /, ""); print; next }
    body { exit }
  ' "$root/.github/workflows/ci.yml" | sed 's/\${{ strategy.job-index }}/0/g'
}

expect_followup() {
  local name="$1" kept_before="$2" expected_calls="$3" expected_log="$4" calls log
  local dir="$scratch/followup-$RANDOM"
  mkdir -p "$dir/scripts" "$dir/.build/DerivedData-test"
  printf '1700000000\n' >"$dir/.build/DerivedData-test/ui-test-start-time.txt"
  cat >"$dir/scripts/collect-ui-test-log.sh" <<'FAKE'
#!/usr/bin/env bash
echo "collected" >>"$(dirname "$0")/../calls"
echo "second copy" >"$2"
FAKE
  chmod +x "$dir/scripts/collect-ui-test-log.sh"
  if [[ -n "$kept_before" ]]; then
    printf '%s\n' "$kept_before" >"$dir/.build/DerivedData-test/ui-test-kept-log-shard-0.txt.gz"
  fi
  followup_script >"$dir/followup.sh"
  if [[ ! -s "$dir/followup.sh" ]]; then
    echo "FAIL: $name: the follow-up step's script was not found in ci.yml" >&2
    exit 1
  fi
  (cd "$dir" && bash followup.sh >"$dir/out" 2>&1) || {
    echo "FAIL: $name: the follow-up script failed" >&2
    cat "$dir/out" >&2
    exit 1
  }
  calls=0
  [[ -f "$dir/calls" ]] && calls="$(wc -l <"$dir/calls" | tr -d ' ')"
  log="$(cat "$dir/.build/DerivedData-test/ui-test-kept-log-shard-0.txt.gz" 2>/dev/null || true)"
  if [[ "$calls" != "$expected_calls" || "$log" != "$expected_log" ]]; then
    echo "FAIL: $name: expected $expected_calls collection(s) and log \"$expected_log\", got $calls and \"$log\"" >&2
    exit 1
  fi
  echo "PASS: $name"
}

expect_followup "a shard that failed its tests keeps the log its test step collected" "first copy" 0 "first copy"
expect_followup "a shard stopped by its timeout gets a log from the follow-up step" "" 1 "second copy"

# The waiting-evidence report reads only GitHub. The fake serves one file per endpoint and applies
# the script's own --jq filter, so the filters are proved too. A log with no file is one GitHub no
# longer serves.
evidence="$scratch/evidence"
mkdir -p "$evidence"
evidence_gh="$scratch/evidence-gh"
cat >"$evidence_gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api ]] || exit 2
path="${2#repos/example/repo/}"
case "$path" in
  commits\?*)
    file="commits-${path##*page=}.json"
    [[ -f "$FAKE_EVIDENCE/$file" ]] || file=empty-list.json
    ;;
  commits/*/pulls) file=pulls.json ;;
  actions/runs\?*page=1) file=runs.json ;;
  actions/runs\?*) file=empty-runs.json ;;
  actions/runs/*/attempts/*/jobs\?*)
    path="${path#actions/runs/}"
    file="jobs-${path%%/*}-$(sed -E 's|.*/attempts/([0-9]+)/.*|\1|' <<<"$path").json"
    ;;
  actions/runs/*/artifacts\?*)
    path="${path#actions/runs/}"
    file="artifacts-${path%%/*}.json"
    ;;
  actions/jobs/*/logs)
    path="${path#actions/jobs/}"
    file="log-${path%%/*}.txt"
    ;;
  *) exit 2 ;;
esac
[[ -f "$FAKE_EVIDENCE/$file" ]] || exit 1
if [[ "${3:-}" == --jq ]]; then
  jq -r "$4" "$FAKE_EVIDENCE/$file"
else
  cat "$FAKE_EVIDENCE/$file"
fi
FAKE
chmod +x "$evidence_gh"

evidence_job() {
  local id="$1" shard="$2" conclusion="$3" started="$4" completed="$5" test_end="$6"
  printf '{"id":%s,"name":"app (%s)","conclusion":"%s","started_at":"%s","completed_at":"%s","steps":[{"name":"Shard %s of 3","started_at":"%s","completed_at":"%s"}]}' \
    "$id" "$shard" "$conclusion" "$started" "$completed" "$shard" "$started" "$test_end"
}

evidence_log() {
  local job="$1" test="$2" result="$3"
  printf "2026-11-27T00:00:00.0000000Z Test Case '-[uniterm_UITests.%s]' %s (1.000 seconds).\n" \
    "$test" "$result" >>"$evidence/log-$job.txt"
}

wheel="LauncherUITests testAShortPaneKeepsTheFilterBoxAndScrollsToTheLastEntry"
shortcut="ShortcutOwnershipUITests testARemapOntoAnAppletKeyWinsAndWarnsOnce"
printf '[]' >"$evidence/empty-list.json"
printf '{"workflow_runs":[]}' >"$evidence/empty-runs.json"
printf '[{"sha":"def","commit":{"message":"Another change","committer":{"date":"2026-11-27T05:00:00Z"}}}]' \
  >"$evidence/commits-1.json"
printf '[{"merged_at":"2026-11-27T10:00:00Z"}]' >"$evidence/pulls.json"
printf '{"artifacts":[]}' >"$evidence/artifacts-3.json"
printf '      - id: tested\n        timeout-minutes: 5\n      - id: test\n        timeout-minutes: 38\n' \
  >"$evidence/ci.yml"

# Run 1 is from before the wheel change landed. Run 2 failed a shard and reran it. Run 3's first
# shard ran to the test step's limit, and its log is gone.
cat >"$evidence/runs.json" <<'RUNS'
{"workflow_runs":[
  {"id":1,"name":"ci","run_attempt":1,"created_at":"2026-11-27T09:00:00Z"},
  {"id":2,"name":"ci","run_attempt":2,"created_at":"2026-11-27T11:00:00Z"},
  {"id":3,"name":"ci","run_attempt":1,"created_at":"2026-11-27T12:00:00Z"},
  {"id":4,"name":"other","run_attempt":1,"created_at":"2026-11-27T12:00:00Z"}]}
RUNS
printf '{"jobs":[{"id":9,"name":"package","conclusion":"success","started_at":"2026-11-27T09:00:00Z","completed_at":"2026-11-27T09:20:00Z"},%s]}' \
  "$(evidence_job 10 0 failure 2026-11-27T09:00:00Z 2026-11-27T09:12:00Z 2026-11-27T09:11:00Z)" >"$evidence/jobs-1-1.json"
printf '{"jobs":[%s,%s]}' \
  "$(evidence_job 20 0 success 2026-11-27T11:00:00Z 2026-11-27T11:10:00Z 2026-11-27T11:09:00Z)" \
  "$(evidence_job 21 1 failure 2026-11-27T11:00:00Z 2026-11-27T11:12:00Z 2026-11-27T11:11:00Z)" >"$evidence/jobs-2-1.json"
printf '{"jobs":[%s,%s]}' \
  "$(evidence_job 22 0 success 2026-11-27T11:00:00Z 2026-11-27T11:10:00Z 2026-11-27T11:09:00Z)" \
  "$(evidence_job 23 1 success 2026-11-27T11:30:00Z 2026-11-27T11:42:00Z 2026-11-27T11:41:00Z)" >"$evidence/jobs-2-2.json"
printf '{"jobs":[%s,%s]}' \
  "$(evidence_job 30 0 cancelled 2026-11-27T12:00:00Z 2026-11-27T12:40:00Z 2026-11-27T12:38:00Z)" \
  "$(evidence_job 31 1 success 2026-11-27T12:00:00Z 2026-11-27T12:10:00Z 2026-11-27T12:09:00Z)" >"$evidence/jobs-3-1.json"
evidence_log 10 "$wheel" passed
evidence_log 10 "$shortcut" failed
evidence_log 20 "$shortcut" passed
evidence_log 21 "$wheel" started
evidence_log 21 "$wheel" failed
evidence_log 22 "$wheel" failed
evidence_log 23 "$wheel" passed
evidence_log 31 "$wheel" passed

expect_evidence() {
  local name="$1" expected="$2"
  CI_WAITING_EVIDENCE_GH="$evidence_gh" CI_WAITING_EVIDENCE_REPO=example/repo FAKE_EVIDENCE="$evidence" \
    CI_WAITING_EVIDENCE_CACHE="$scratch/evidence-cache-$RANDOM" CI_WAITING_EVIDENCE_WORKFLOW="$evidence/ci.yml" \
    bash "$root/scripts/ci-waiting-evidence.sh" >"$scratch/evidence-out" 2>&1 || {
    echo "FAIL: $name: the report exited with an error" >&2
    cat "$scratch/evidence-out" >&2
    exit 1
  }
  if ! grep -qF -- "$expected" "$scratch/evidence-out"; then
    echo "FAIL: $name: expected \"$expected\"" >&2
    cat "$scratch/evidence-out" >&2
    exit 1
  fi
  echo "PASS: $name"
}

expect_evidence "a wheel change that has not landed counts nothing" "WAITING: 0 of 33."
expect_evidence "a shortcut test failure fires before the wheel change lands" "run 1 attempt 1, app (0)"

printf '[{"sha":"abc","commit":{"message":"Send every UI test wheel through one settled call\\n\\nBody","committer":{"date":"2026-11-27T04:00:00Z"}}}]' \
  >"$evidence/commits-2.json"
expect_evidence "the count finds a wheel change behind a page of newer commits, starts at its merge, restarts at a failure, and skips a carried job" \
  "WAITING: about 2 of 33, since it landed at 2026-11-27T10:00:00Z."
expect_evidence "a failure that breaks the streak is named" "failed in run 2 attempt 1, app (1)"
expect_evidence "a job at the test step's limit fires and names its missing upload" \
  "run 3 attempt 1, app (0): the test step ran 38 minutes, and ui-test-results-shard-0-attempt-1 is missing"
expect_evidence "a job with no log is listed under the count, not judged" "    run 3 attempt 1, app (0), cancelled"

printf '{"artifacts":[{"name":"ui-test-results-shard-0-attempt-1"}]}' >"$evidence/artifacts-3.json"
expect_evidence "a job at the limit names its upload" "ui-test-results-shard-0-attempt-1 was uploaded"
