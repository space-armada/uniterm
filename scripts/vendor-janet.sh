#!/usr/bin/env bash
#
# Vendors the pinned Janet release into the CJanet target.
#
# Usage:
#   scripts/vendor-janet.sh             fetch, verify, build the amalgamation, and copy it in
#   scripts/vendor-janet.sh --record    the same, then write the output hashes into janet.pin
#   scripts/vendor-janet.sh --verify    check the vendored files against janet.pin, offline
#
# The tarball is checked by the sha256 in janet.pin, and by the commit its git archive header
# names. Janet's own make builds the amalgamation, so the generated janet.c is a build product. The
# pin records its sha256 too, and a build that drifts from the pin fails. The work happens under
# .cache/janet, since a sandboxed shell cannot write to the system temp folder.
#
# Run it when janet.pin changes. Then run make licenses and commit the result.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_FILE="${JANET_PIN_FILE:-$ROOT/janet.pin}"
CACHE="${JANET_CACHE_DIR:-$ROOT/.cache/janet}"
TARGET="${JANET_TARGET_DIR:-$ROOT/Packages/UnitermKit/Sources/CJanet}"
NOTICES="${JANET_NOTICES_DIR:-$ROOT/ThirdParty/janet}"
ADDITIONS="$ROOT/scripts/janet/janetconf-additions.h"
MODE="${1:-fetch}"

die() {
  echo "error: $*" >&2
  exit 1
}

sha256() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

# shellcheck disable=SC1090
. "$PIN_FILE"

check_output() {
  local label="$1" actual="$2" pinned="$3"
  [ -n "$pinned" ] || die "janet.pin has no $label. Run scripts/vendor-janet.sh --record."
  [ "$actual" = "$pinned" ] || die "$label is $actual, and janet.pin says $pinned."
}

verify_vendored() {
  check_output "JANET_C_SHA256" "$(sha256 "$TARGET/janet.c")" "${JANET_C_SHA256:-}"
  check_output "JANET_H_SHA256" "$(sha256 "$TARGET/janet.h")" "${JANET_H_SHA256:-}"
  check_output "JANETCONF_H_SHA256" "$(sha256 "$TARGET/janetconf.h")" "${JANETCONF_H_SHA256:-}"
  check_output "SHELL_C_SHA256" "$(sha256 "$TARGET/Unbuilt/shell.c")" "${SHELL_C_SHA256:-}"
  check_output "LICENSE_SHA256" "$(sha256 "$NOTICES/LICENSE")" "${LICENSE_SHA256:-}"
}

if [ "$MODE" = "--verify" ]; then
  verify_vendored
  echo "The vendored Janet matches janet.pin ($JANET_TAG)."
  exit 0
fi

mkdir -p "$CACHE/dl"
tarball="$CACHE/dl/janet-$JANET_TAG.tar.gz"

if [ ! -f "$tarball" ]; then
  curl --fail --silent --show-error --location \
    --output "$tarball" "https://github.com/janet-lang/janet/archive/refs/tags/$JANET_TAG.tar.gz"
fi

check_output "the tarball sha256" "$(sha256 "$tarball")" "$JANET_TARBALL_SHA256"

commit="$(gzip -dc <"$tarball" 2>/dev/null | git get-tar-commit-id || true)"
[ "$commit" = "$JANET_COMMIT" ] || die "the tarball is commit $commit, and janet.pin says $JANET_COMMIT."

work="$(mktemp -d "$CACHE/work.XXXXXX")"
trap 'rm -rf "$work"' EXIT

tar -xzf "$tarball" -C "$work" --strip-components=1

if ! (cd "$work" && make build/c/janet.c build/c/shell.c >"$work/build.log" 2>&1); then
  cat "$work/build.log" >&2
  die "Janet's make failed."
fi

mkdir -p "$TARGET" "$TARGET/Unbuilt" "$NOTICES"

cp "$work/build/c/janet.c" "$TARGET/janet.c"
cp "$work/src/include/janet.h" "$TARGET/janet.h"
cp "$work/build/c/shell.c" "$TARGET/Unbuilt/shell.c"
cp "$work/LICENSE" "$NOTICES/LICENSE"

upstream_conf="$work/src/conf/janetconf.h"
last_endif="$(grep -n '^#endif' "$upstream_conf" | tail -1 | cut -d: -f1)"

{
  head -n "$((last_endif - 1))" "$upstream_conf"
  cat "$ADDITIONS"
  echo
  tail -n "+$last_endif" "$upstream_conf"
} >"$TARGET/janetconf.h"

if [ "$MODE" = "--record" ]; then
  python3 -I - "$PIN_FILE" \
    "JANET_C_SHA256=$(sha256 "$TARGET/janet.c")" \
    "JANET_H_SHA256=$(sha256 "$TARGET/janet.h")" \
    "JANETCONF_H_SHA256=$(sha256 "$TARGET/janetconf.h")" \
    "SHELL_C_SHA256=$(sha256 "$TARGET/Unbuilt/shell.c")" \
    "LICENSE_SHA256=$(sha256 "$NOTICES/LICENSE")" <<'PY'
import sys

path = sys.argv[1]
updates = dict(item.split("=", 1) for item in sys.argv[2:])
lines = open(path).read().splitlines()
kept = [line for line in lines if line.split("=", 1)[0] not in updates]
kept += [f"{key}={value}" for key, value in updates.items()]
open(path, "w").write("\n".join(kept) + "\n")
PY
  echo "Recorded the output hashes in $PIN_FILE."
  exit 0
fi

verify_vendored
echo "Vendored Janet $JANET_TAG into $TARGET."
