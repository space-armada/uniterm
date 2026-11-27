#!/bin/bash
# Builds uniterm and runs it for one hand check, with the build stamped into the runner.
#
# Run it from the root of a uniterm checkout:
#
#   <bundle>/scripts/launch.sh <check-id> [--fresh] [--no-build] [--env KEY=VALUE]... [-- <app args>]
#
# The check's "launch" field picks the state the app starts with:
#   isolated             a throwaway state folder, wiped on every launch
#   isolated-persistent  a state folder kept across launches of the same check, until --fresh
#   real                 your real settings, layout, and browser store
#
# The state folder is .build/hand-checks/<check-id>/ in the checkout. The app runs in the foreground, so this
# terminal shows its logs and any crash. Quitting the app ends the script.

set -euo pipefail

BUNDLE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(pwd)"

usage() {
  sed -n '4,6p' "$0" | sed 's/^# *//'
  exit 2
}

if [[ ! -f "$REPO/Makefile" || ! -d "$REPO/uniterm.xcodeproj" ]]; then
  echo "launch.sh: run this from the root of a uniterm checkout. $REPO is not one." >&2
  exit 2
fi

[[ $# -ge 1 ]] || usage
CHECK="$1"
shift

CHECK_FILE="$BUNDLE/checks/$CHECK/check.json"
if [[ ! -f "$CHECK_FILE" ]]; then
  echo "launch.sh: no check named '$CHECK'. The check ids are the folder names in $BUNDLE/checks." >&2
  exit 2
fi

FRESH=0
BUILD=1
EXTRA_ENV=()
APP_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh) FRESH=1 ;;
    --no-build) BUILD=0 ;;
    --env)
      [[ $# -ge 2 && "$2" == *=* ]] || { echo "launch.sh: --env takes KEY=VALUE" >&2; exit 2; }
      EXTRA_ENV+=("$2")
      shift
      ;;
    --)
      shift
      APP_ARGS=("$@")
      break
      ;;
    *) echo "launch.sh: unknown option '$1'" >&2; usage ;;
  esac
  shift
done

MODE="$(plutil -extract launch raw -o - "$CHECK_FILE" 2>/dev/null || echo isolated)"

if [[ "$MODE" == "none" ]]; then
  echo "launch.sh: '$CHECK' needs no app launch. Follow its guide instead." >&2
  exit 2
fi

if [[ $BUILD -eq 1 ]]; then
  echo "launch.sh: building with make build"
  make build
fi

APP="$REPO/.build/DerivedData/Build/Products/Debug/uniterm.app/Contents/MacOS/uniterm"
if [[ ! -x "$APP" ]]; then
  echo "launch.sh: no Debug build at $APP. Run without --no-build." >&2
  exit 1
fi

json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

COMMIT="$(git -C "$REPO" rev-parse HEAD)"
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
DIRTY="$(git -C "$REPO" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
STAMP_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
  printf '(window.UHC_STAMPS = window.UHC_STAMPS || []).push({'
  printf '"check": %s, ' "$(json_string "$CHECK")"
  printf '"mode": %s, ' "$(json_string "$MODE")"
  printf '"commit": %s, ' "$(json_string "$COMMIT")"
  printf '"branch": %s, ' "$(json_string "$BRANCH")"
  printf '"dirtyFiles": %s, ' "$DIRTY"
  printf '"configuration": "Debug", '
  printf '"macos": %s, ' "$(json_string "$(sw_vers -productVersion) ($(sw_vers -buildVersion))")"
  printf '"arch": %s, ' "$(json_string "$(uname -m)")"
  printf '"time": %s' "$(json_string "$STAMP_TIME")"
  printf '});\n'
} >> "$BUNDLE/stamp.js"

echo "launch.sh: stamped ${COMMIT:0:12} on $BRANCH, $DIRTY modified files. Reload the runner to see it."

STATE="$REPO/.build/hand-checks/$CHECK"
RUN_ENV=("UHC_CHECK=$CHECK" "UHC_BUNDLE=$BUNDLE" "UHC_STATE=$STATE" "UNITERM_HAND_CHECK=$CHECK")

if [[ "$MODE" == "isolated" || "$MODE" == "isolated-persistent" ]]; then
  if [[ "$MODE" == "isolated" || $FRESH -eq 1 ]]; then
    rm -rf "$STATE"
  fi
  mkdir -p "$STATE"

  # A socket path holds 104 bytes, so the script folder lives under /tmp, named by the check.
  SOCKET_DIR="/tmp/uhc-$(id -u)-$(printf '%s' "$CHECK" | cksum | cut -d' ' -f1)"
  mkdir -p "$SOCKET_DIR"
  chmod 700 "$SOCKET_DIR"

  RUN_ENV+=(
    "UNITERM_DEFAULTS_PATH=$STATE/defaults"
    "UNITERM_TERMINAL_DIR=$STATE/terminal"
    "UNITERM_LAYOUT_DIR=$STATE/layout"
    "UNITERM_BROWSER_DIR=$STATE/browser"
    "UNITERM_CONTROLLER_RUNS_DIR=$STATE/controller-runs"
    "UNITERM_CONTROLLER_POLICY_DIR=$STATE/controller-policy"
    "UNITERM_SENT_DIR=$STATE/sent"
    "UNITERM_SCRIPT_DIR=$SOCKET_DIR"
    "UHC_SOCKET_DIR=$SOCKET_DIR"
  )
  echo "launch.sh: state folder $STATE"
else
  echo "launch.sh: '$CHECK' runs with your real settings, layout, and browser store."
fi

RUN_ENV+=("${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}")

PID_FILES=("$BUNDLE/.last-launch-pid")
[[ -d "$STATE" ]] && PID_FILES+=("$STATE/app.pid")

# The app runs in the foreground, never with `&`. A background job of a script starts with SIGINT ignored, and
# the app's terminals would inherit that, so Ctrl-C would stop working in them. The inner shell writes its own
# pid, which the exec hands to the app.
set +e
env "${RUN_ENV[@]}" /bin/bash -c '
  for f in "$@"; do
    [[ "$f" == "--" ]] && break
    echo $$ > "$f"
  done
  while [[ "$1" != "--" ]]; do shift; done
  shift
  echo "launch.sh: uniterm is running as process $$"
  exec "$@"
' launch "${PID_FILES[@]}" -- "$APP" "${APP_ARGS[@]+"${APP_ARGS[@]}"}"
STATUS=$?
set -e

if [[ $STATUS -gt 128 ]]; then
  echo "launch.sh: uniterm ended on signal $((STATUS - 128)), status $STATUS. That is a crash unless the check sent the signal."
  echo "launch.sh: crash reports are in ~/Library/Logs/DiagnosticReports, named uniterm-*.ips."
else
  echo "launch.sh: uniterm exited with status $STATUS."
fi

exit "$STATUS"
