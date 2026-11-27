#!/usr/bin/env bash
#
# Fails when a UI test sends an XCUI wheel outside the shared call.
#
# A wheel goes to whatever is under the pointer when it is delivered. The shared call, sendWheel in
# UITests/UITestWheel.swift, settles the pointer on the target before it sends one. A raw
# scroll(byDeltaX:deltaY:) skips that, and the race it leaves shows only on CI. The check exempts
# one call: the one in the helper's file whose receiver is wheelPoint. Comments are ignored, and a
# call split across lines still matches.
#
# Usage: scripts/check-ui-wheel.sh [root]
#        scripts/check-ui-wheel.sh --self-test
# The optional root lets a test point the check at a scratch copy of the tree.

set -euo pipefail

HELPER="UITests/UITestWheel.swift"

# Prints "path:line:receiver" for each scroll(byDeltaX:...) call in a Swift file. One pass blanks
# comments and the contents of string literals, so a "//" or "/*" inside a string starts no
# comment and a call after it is still seen. Newlines survive, so the line numbers hold.
find_wheels() {
  perl -0777 -ne '
    s{("""(?:.|\n)*?""")|("(?:\\.|[^"\\\n])*")|(//[^\n]*)|(/\*.*?\*/)}{
      my ($triple, $string) = ($1, $2);
      if (defined $string) { q("") }
      else { (my $m = $&) =~ s/[^\n]/ /g; $m }
    }gse;
    while (/(?:(\w+)\s*\.\s*)?scroll\s*\(\s*byDeltaX\s*:/g) {
      my $receiver = defined $1 ? $1 : "";
      my $line = 1 + (() = substr($_, 0, $-[0]) =~ /\n/g);
      print "$ARGV:$line:$receiver\n";
    }
  ' "$1"
}

check_root() {
  local root="$1"
  local status=0
  local helper_calls=0
  local file match line receiver

  if [ ! -d "$root/UITests" ]; then
    echo "error: $root/UITests does not exist, so no wheel was checked." >&2
    return 1
  fi

  while IFS= read -r file; do
    relative="${file#"$root"/}"

    while IFS= read -r match; do
      [ -n "$match" ] || continue

      rest="${match#*:}"
      line="${rest%%:*}"
      receiver="${rest#*:}"

      if [ "$relative" = "$HELPER" ] && [ "$receiver" = "wheelPoint" ] && [ "$helper_calls" = "0" ]; then
        helper_calls=1
        continue
      fi

      echo "error: $relative:$line sends a wheel outside sendWheel. Use sendWheel from $HELPER." >&2
      status=1
    done < <(find_wheels "$file")
  done < <(find "$root/UITests" -name '*.swift' | sort)

  return "$status"
}

# Each case writes a scratch tree, runs the check on it, and compares the outcome.
scratch=""

self_test() {
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/check-ui-wheel.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT

  local failures=0

  # expect NAME accept|reject [FILE:LINE]. A reject must also report that file and line.
  expect() {
    local name="$1" want="$2" where="${3:-}" got=0 output
    output="$(check_root "$scratch/case" 2>&1)" || got=$?

    if [ "$want" = "reject" ] && [ "$got" = "0" ]; then
      echo "self-test: $name was accepted" >&2
      failures=1
    elif [ "$want" = "reject" ] && [[ "$output" != *"error: $where "* ]]; then
      echo "self-test: $name was rejected without $where: $output" >&2
      failures=1
    elif [ "$want" = "accept" ] && [ "$got" != "0" ]; then
      echo "self-test: $name was rejected: $output" >&2
      failures=1
    fi

    rm -rf "$scratch/case"
    mkdir -p "$scratch/case/UITests"
  }

  mkdir -p "$scratch/case/UITests"

  printf 'func f() {\n  list\n    .scroll(\n      byDeltaX: 0, deltaY: 1)\n}\n' \
    >"$scratch/case/UITests/A.swift"
  expect "a raw wheel split across lines" reject UITests/A.swift:2

  printf '// list.scroll(byDeltaX: 0, deltaY: 1)\n/* a.scroll(byDeltaX: 0,\n deltaY: 1) */\nlet x = 1\n' \
    >"$scratch/case/UITests/A.swift"
  expect "a wheel in a comment" accept

  printf 'func f() {\n  wheelPoint.scroll(byDeltaX: 0, deltaY: 1)\n}\n' \
    >"$scratch/case/$HELPER"
  expect "the helper's own call" accept

  printf 'func f() {\n  wheelPoint.scroll(byDeltaX: 0, deltaY: 1)\n  target.scroll(byDeltaX: 0, deltaY: 1)\n}\n' \
    >"$scratch/case/$HELPER"
  expect "a raw wheel elsewhere in the helper's file" reject UITests/UITestWheel.swift:3

  printf 'func f() {\n  wheelPoint.scroll(byDeltaX: 0, deltaY: 1)\n}\n' \
    >"$scratch/case/UITests/A.swift"
  expect "the helper's call shape in another file" reject UITests/A.swift:2

  printf 'let u = "http://x"; list.scroll(byDeltaX: 0, deltaY: 1)\n' \
    >"$scratch/case/UITests/A.swift"
  expect "a wheel after a slash pair in a string" reject UITests/A.swift:1

  printf 'let s = "/*"\nlist.scroll(byDeltaX: 0, deltaY: 1)\nlet t = "*/"\n' \
    >"$scratch/case/UITests/A.swift"
  expect "a wheel after a block comment opener in a string" reject UITests/A.swift:2

  printf 'let s = "say \\"//\\" now"; list.scroll(byDeltaX: 0, deltaY: 1)\n' \
    >"$scratch/case/UITests/A.swift"
  expect "a wheel after an escaped quote and a slash pair" reject UITests/A.swift:1

  printf 'let s = "list.scroll(byDeltaX: 0, deltaY: 1)"\n' >"$scratch/case/UITests/A.swift"
  expect "a wheel's text inside a string" accept

  rm -rf "$scratch/case"
  expect "a missing UITests directory" reject "$scratch/case/UITests"

  if [ "$failures" = "0" ]; then
    echo "The wheel check rejects and accepts the cases it should."
  fi

  return "$failures"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if check_root "$ROOT"; then
  echo "UI tests send wheels only through sendWheel."
else
  exit 1
fi
