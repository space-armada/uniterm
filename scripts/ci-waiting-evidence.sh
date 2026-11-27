#!/usr/bin/env bash
set -euo pipefail

# Some checks pass only after CI produces something no local run can cause: enough clean runs of a
# test after its fix lands, a failure of one rare flake, or a job that reaches its time limit. This
# reports each of them from GitHub, so nobody rereads CI by hand to learn that nothing changed.
#
# The clean count is a floor, not the count itself. It counts only runs created after the fix
# merged, and it lets every failure of the test break the streak. The closing rule in
# spec/flaky-tests.md decides the real count, and may count more.
#
# Finished runs never change, so each answer from GitHub is kept under .build and read once.

root="$(cd "$(dirname "$0")/.." && pwd)"
gh="${CI_WAITING_EVIDENCE_GH:-gh}"
repo="${CI_WAITING_EVIDENCE_REPO:-space-armada/uniterm}"
cache="${CI_WAITING_EVIDENCE_CACHE:-$root/.build/ci-waiting-evidence}"
workflow="${CI_WAITING_EVIDENCE_WORKFLOW:-$root/.github/workflows/ci.yml}"

wheel_subject="Send every UI test wheel through one settled call"
wheel_test="LauncherUITests testAShortPaneKeepsTheFilterBoxAndScrollsToTheLastEntry"
wheel_count=33
stall_test="ShortcutOwnershipUITests testARemapOntoAnAppletKeyWinsAndWarnsOnce"

# The first main push whose failed shards upload the kept log. Nothing earlier can hold evidence.
since="2026-11-26T04:23:45Z"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$cache"

fail() {
  echo "$1" >&2
  exit 1
}

# Prints every page of a list endpoint through one filter. The path already holds a query.
pages() {
  local path="$1" filter="$2" page=1 out

  while :; do
    out="$("$gh" api "$path&per_page=100&page=$page" --jq "$filter")" || fail "Could not read $path from GitHub."
    [[ -n "$out" ]] || break

    printf '%s\n' "$out"
    page=$((page + 1))
  done
}

test_step_limit() {
  local minutes
  minutes="$(awk '/id: test$/ { found = 1 } found && /timeout-minutes:/ { print $2; exit }' "$workflow")"
  [[ "$minutes" =~ ^[0-9]+$ ]] || fail "Could not read the test step's time limit from $workflow."

  echo $((minutes * 60))
}

# When the wheel change reached main, or nothing when it has not. A merged PR's merge time is what
# matters, since the commit's own date is from before it landed.
wheel_landed_at() {
  local found sha date merged

  found="$(pages "repos/$repo/commits?since=$since" \
    ".[] | select(.commit.message | startswith(\"$wheel_subject\")) | \"\(.sha) \(.commit.committer.date)\"")"
  [[ -n "$found" ]] || return 0

  read -r sha date <<<"$(tail -n 1 <<<"$found")"
  merged="$("$gh" api "repos/$repo/commits/$sha/pulls" \
    --jq '[.[] | select(.merged_at != null) | .merged_at] | sort | first // empty')" \
    || fail "Could not list the PRs that merged $sha."

  echo "${merged:-$date}"
}

# One line per app job of a run attempt: id, name, conclusion, start, end, and the test step's
# length in seconds.
attempt_jobs() {
  local run="$1" attempt="$2" file="$cache/jobs-$1-$2.tsv"

  if [[ ! -f "$file" ]]; then
    "$gh" api "repos/$repo/actions/runs/$run/attempts/$attempt/jobs?per_page=100" --jq '
      def seconds: sub("\\.[0-9]+"; "") | fromdateiso8601;
      .jobs[] | select(.name | startswith("app (")) |
      ((.steps // []) | map(select(.name | startswith("Shard "))) | first) as $test |
      [.id, .name, (.conclusion // "none"), .started_at, (.completed_at // ""),
       (if $test != null and $test.started_at != null and $test.completed_at != null
        then ($test.completed_at | seconds) - ($test.started_at | seconds) else 0 end)] | @tsv' \
      >"$scratch/jobs" || fail "Could not list the jobs of run $run attempt $attempt."
    mv "$scratch/jobs" "$file"
  fi

  cat "$file"
}

# The two watched tests' own started, passed, and failed lines from a job's log. A log GitHub no
# longer serves prints nothing and fails, and is asked for again next time.
job_test_lines() {
  local job="$1" file="$cache/tests-$1.txt"

  if [[ ! -f "$file" ]]; then
    "$gh" api "repos/$repo/actions/jobs/$job/logs" >"$scratch/log" 2>/dev/null || return 1
    grep -E "Test Case '-\[uniterm_UITests\.($wheel_test|$stall_test)\]' (started|passed|failed)" \
      "$scratch/log" >"$scratch/tests" || true
    mv "$scratch/tests" "$file"
  fi

  cat "$file"
}

verdict() {
  local lines="$1" test="$2"

  if grep -qF "$test]' failed" <<<"$lines"; then
    echo failed
  elif grep -qF "$test]' passed" <<<"$lines"; then
    echo passed
  elif grep -qF "$test]' started" <<<"$lines"; then
    echo unfinished
  else
    echo absent
  fi
}

limit="$(test_step_limit)"
landed="$(wheel_landed_at)"

: >"$scratch/seen"
: >"$scratch/wheel"
: >"$scratch/stall"
: >"$scratch/limit"
: >"$scratch/unread"

pages "repos/$repo/actions/runs?status=completed&created=%3E%3D$since" \
  '.workflow_runs[] | select(.name == "ci") | "\(.id) \(.run_attempt) \(.created_at)"' >"$scratch/runs"

while read -r run attempts created; do
  [[ -n "$run" ]] || continue

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    while IFS=$'\t' read -r job name conclusion started completed test_seconds; do
      # A rerun attempt lists the jobs it did not rerun again, with their first times.
      key="$run $name $started"
      if grep -qxF "$key" "$scratch/seen"; then
        continue
      fi
      echo "$key" >>"$scratch/seen"

      where="run $run attempt $attempt, $name"
      holds_wheel=false
      if [[ -n "$landed" && ! "$created" < "$landed" ]]; then
        holds_wheel=true
      fi

      if [[ "$test_seconds" -ge $((limit - 30)) ]]; then
        shard="${name//[^0-9]/}"
        artifact="ui-test-results-shard-$shard-attempt-$attempt"
        uploaded="$("$gh" api "repos/$repo/actions/runs/$run/artifacts?per_page=100" \
          --jq "[.artifacts[] | select(.name == \"$artifact\")] | length")" \
          || fail "Could not list the artifacts of run $run."
        if [[ "$uploaded" -gt 0 ]]; then
          echo "$where: the test step ran $((test_seconds / 60)) minutes, and $artifact was uploaded" >>"$scratch/limit"
        else
          echo "$where: the test step ran $((test_seconds / 60)) minutes, and $artifact is missing" >>"$scratch/limit"
        fi
      fi

      if [[ "$holds_wheel" == false && "$conclusion" == success ]]; then
        continue
      fi

      if ! lines="$(job_test_lines "$job")"; then
        echo "$where" >>"$scratch/unread"
        continue
      fi

      if [[ "$(verdict "$lines" "$stall_test")" == failed ]]; then
        echo "$where" >>"$scratch/stall"
      fi

      if [[ "$holds_wheel" == true ]]; then
        printf '%s\t%s\t%s\n' "$completed" "$(verdict "$lines" "$wheel_test")" "$where" >>"$scratch/wheel"
      fi
    done < <(attempt_jobs "$run" "$attempt")
  done
done <"$scratch/runs"

streak=0
breaks=""
while IFS=$'\t' read -r _ result where; do
  case "$result" in
    passed) streak=$((streak + 1)) ;;
    failed | unfinished)
      streak=0
      breaks+="  $result in $where"$'\n'
      ;;
  esac
done < <(sort "$scratch/wheel")

echo "Clean runs of the launcher scroll test since the wheel change landed:"
if [[ -z "$landed" ]]; then
  echo "  WAITING: 0 of $wheel_count. \"$wheel_subject\" has not reached main."
elif [[ "$streak" -ge "$wheel_count" ]]; then
  echo "  FIRED: at least $streak of $wheel_count, since it landed at $landed."
else
  echo "  WAITING: at least $streak of $wheel_count, since it landed at $landed."
fi
printf '%s' "$breaks"

echo "Failures of the remapped shortcut test on CI since $since:"
if [[ -s "$scratch/stall" ]]; then
  echo "  FIRED: read each failed shard's kept log for the Cmd-T events."
  sed 's/^/  /' "$scratch/stall"
else
  echo "  WAITING: none."
fi

echo "App jobs whose test step reached its $((limit / 60)) minute limit since $since:"
if [[ -s "$scratch/limit" ]]; then
  echo "  FIRED:"
  sed 's/^/  /' "$scratch/limit"
else
  echo "  WAITING: none."
fi

if [[ -s "$scratch/unread" ]]; then
  echo "Logs GitHub would not serve, so these jobs are not counted above:"
  sed 's/^/  /' "$scratch/unread"
fi
