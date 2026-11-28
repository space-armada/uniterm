#!/usr/bin/env bash
#
# Runs the UI tests, given as an xcodebuild command: run-ui-tests.sh xcodebuild ... test
#
# UI tests drive the app through Launch Services and the Accessibility API. Without a GUI session
# the run cannot start. Without Accessibility permission it fails while enabling automation. This
# script names those causes instead of leaving a bare xcodebuild failure.

set -euo pipefail

# UI tests drive the one screen and keyboard. Two runs at once, from two sessions or worktrees, steal
# each other's focus and keys, so a run waits for the screen. The lock is per user, outside every
# checkout, so every worktree shares it.
lock="${UNITERM_UI_LOCK_FILE:-/tmp/uniterm-ui-tests-$(id -u).lock}"
holder="$lock.holder"

if [[ -z "${UNITERM_UI_LOCK_HELD:-}" ]]; then
  if ! lockf -ks -t 0 "$lock" true; then
    echo "Another UI test run holds the screen: $(cat "$holder" 2>/dev/null || echo "unknown run")." >&2
    echo "Waiting for it to finish." >&2
  fi

  UNITERM_UI_LOCK_HELD=1 exec lockf -k "$lock" "$0" "$@"
fi

printf 'pid %s, started %s, in %s\n' "$$" "$(date '+%H:%M:%S')" "$PWD" >"$holder"

if ! swift -e 'import CoreGraphics; exit(CGSessionCopyCurrentDictionary() == nil ? 1 : 0)' 2>/dev/null; then
  echo "error: UI tests need a logged-in GUI session, and this shell has none." >&2
  echo "Run make test-app from Terminal on the desktop." >&2
  exit 1
fi

# Record the start time for log collection. The timestamp is taken after the lock, so another
# run's lines never fall in the window.
start_time=$(date +%s)

# Write the start time to a file for CI to pick up if the test step times out.
if [[ -n "${UNITERM_UI_KEPT_LOG:-}" ]]; then
  kept_dir="$(dirname "$UNITERM_UI_KEPT_LOG")"
  start_time_file="$kept_dir/ui-test-start-time.txt"
  mkdir -p "$kept_dir"
  echo "$start_time" >"$start_time_file"
fi

log="$(mktemp "${TMPDIR:-/tmp}/uniterm-ui-tests.XXXXXX")"
trap 'rm -f "$log" "$holder"' EXIT

if "$@" 2>&1 | tee "$log"; then
  exit 0
fi

if grep -qiE 'automation mode|not authorized|failed to initialize for UI testing|timed out while loading accessibility' "$log"; then
  echo "error: the UI tests could not drive the app. Grant Accessibility permission to Xcode and to the" >&2
  echo "terminal running make, in System Settings > Privacy & Security > Accessibility. Then run again." >&2
fi

# After a failed run, keep the testmanagerd log and the runner's own marks from the run's window.
if [[ -n "${UNITERM_UI_KEPT_LOG:-}" ]]; then
  "$(dirname "$0")/collect-ui-test-log.sh" "$start_time" "$UNITERM_UI_KEPT_LOG"
fi

exit 1
