#!/usr/bin/env bash
#
# Fails when an external version moves off 0 without being declared stable.
#
# An external version is one that a program or file uniterm does not build names or checks. Each
# stays at 0 until uniterm's maintainers declare it version 1. The declaration is an entry in
# spec/declared-stable-versions.md. This check reads the named constants below and nothing else. It
# never searches for the word "version", so an internal version, such as DocumentWire's, the layout
# file's, or the policy file's format, is outside it.
#
# Usage: scripts/check-external-versions.sh [root]
#        scripts/check-external-versions.sh --self-test
# The optional root lets a test point the check at a scratch copy of the tree.

set -euo pipefail

SOURCES="Packages/UnitermKit/Sources"
LIST="spec/declared-stable-versions.md"

# Prints the file with comments, and the contents of string literals, blanked. Newlines survive.
strip_comments() {
  perl -0777 -ne '
    s{("""(?:.|\n)*?""")|("(?:\\.|[^"\\\n])*")|(//[^\n]*)|(/\*.*?\*/)}{
      my ($triple, $string) = ($1, $2);
      if (defined $string) { q("") }
      else { (my $m = $&) =~ s/[^\n]/ /g; $m }
    }gse;
    print;
  ' "$1"
}

# Prints the names listed as declared stable, one for each bullet under "## Declared stable".
declared_names() {
  local list="$1"

  [ -f "$list" ] || return 0

  perl -ne '
    if (/^##\s+Declared stable\s*$/) { $in = 1; next }
    if (/^##\s/) { $in = 0 }
    print "$1\n" if $in && /^[-*]\s+`([^`]+)`/;
  ' "$list"
}

# Prints the number a named constant holds, or nothing when the declaration is not found.
# The pattern holds the surrounding declaration and one capture group for the number.
read_constant() {
  local file="$1" pattern="$2"

  strip_comments "$file" | perl -0777 -ne 'print "$1\n" if /'"$pattern"'/s' | head -n 1
}

check_root() {
  local root="$1"
  local status=0
  local declared
  declared="$(declared_names "$root/$LIST")"

  fail() {
    echo "error: $*" >&2
    status=1
  }

  # check_value NAME FILE VALUE. A value other than 0 passes only when NAME is on the list.
  check_value() {
    local name="$1" file="$2" value="$3"

    if [ "$value" = "0" ]; then
      return 0
    fi

    if printf '%s\n' "$declared" | grep -Fxq -- "$name"; then
      return 0
    fi

    fail "$name is $value in $file, and an external version stays 0 until uniterm's maintainers declare it. It is not on the declared-stable list, $LIST. Only the maintainers add to that list."
  }

  # check_constant NAME FILE PATTERN. The pattern's one capture group is the number.
  check_constant() {
    local name="$1" file="$2" pattern="$3" value

    if [ ! -f "$root/$file" ]; then
      fail "$file does not exist, so $name was not read."
      return 0
    fi

    value="$(read_constant "$root/$file" "$pattern")"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
      fail "$name was not found in $file, so it was not checked. Update scripts/check-external-versions.sh if it moved."
      return 0
    fi

    check_value "$name" "$file" "$value"
  }

  check_constant "ScriptProtocol.version" "$SOURCES/ScriptWire/ScriptProtocol.swift" \
    'enum\s+ScriptProtocol\s*\{\s*(?:public\s+)?static\s+let\s+version\s*(?::\s*\w+)?\s*=\s*(\d+)'

  check_constant "ExecProtocol.version" "$SOURCES/ExecDriver/ExecProtocol.swift" \
    'enum\s+ExecProtocol\s*\{\s*(?:public\s+)?static\s+let\s+version\s*(?::\s*\w+)?\s*=\s*(\d+)'

  check_constant "ControllerDescriptor.format" "$SOURCES/ControllerPackage/ControllerDescriptor.swift" \
    'struct\s+ControllerDescriptor\b[^{]*\{\s*(?:public\s+)?static\s+let\s+format\s*(?::\s*\w+)?\s*=\s*(\d+)'

  check_constant "UNITERM_JANET_API_VERSION" "$SOURCES/CJanet/include/uniterm_janet.h" \
    '#define\s+UNITERM_JANET_API_VERSION\s+(\d+)'

  if [ ! -d "$root/$SOURCES" ]; then
    fail "$SOURCES does not exist, so no command schema was checked."
    return "$status"
  fi

  local schemas=0 file relative line text name major minor version

  while IFS= read -r file; do
    relative="${file#"$root"/}"

    # Prints "line<TAB>applet type expression<TAB>major<TAB>minor" for each construction, and
    # "line<TAB>?" for one it cannot read.
    while IFS=$'\t' read -r line text name major minor; do
      [ -n "$line" ] || continue
      schemas=$((schemas + 1))

      if [ "$text" = "?" ]; then
        fail "$relative:$line builds an AppletCommandSchema this check cannot read. Write its version as AppletSchemaVersion(major, minor) with numbers, or teach scripts/check-external-versions.sh the new form."
        continue
      fi

      # A schema at 0.0 is at 0. Any other pair, such as 0.1 or 1.0, needs a declaration.
      version="$major.$minor"

      if [ "$version" = "0.0" ]; then
        version=0
      fi

      check_value "command schema $name" "$relative:$line" "$version"
    done < <(strip_comments "$file" | perl -0777 -ne '
      while (/(?<![\w.])AppletCommandSchema\s*\(/g) {
        my $rest = substr($_, $+[0]);
        my $line = 1 + (() = substr($_, 0, $-[0]) =~ /\n/g);

        if ($rest =~ /\A\s*appletType\s*:\s*([^,]+?)\s*,\s*version\s*:\s*AppletSchemaVersion\s*\(\s*(\d+)\s*(?:,\s*(\d+)\s*)?\)/s) {
          my $minor = defined $3 ? $3 : 0;
          print "$line\tok\t$1\t$2\t$minor\n";
        } else {
          print "$line\t?\n";
        }
      }

      # Forms that build or rename the type without the plain call: an explicit init, a typealias,
      # and a contextual init. The scan cannot read their version, so each one fails.
      while (/AppletCommandSchema\s*\.\s*init\s*\(|typealias\s+\w+\s*=\s*(?:\w+\.)*AppletCommandSchema\b|:\s*AppletCommandSchema\s*=\s*\.init\b/g) {
        my $line = 1 + (() = substr($_, 0, $-[0]) =~ /\n/g);
        print "$line\t?\n";
      }
    ')
  done < <(grep -rl 'AppletCommandSchema' "$root/$SOURCES" --include='*.swift' | sort)

  if [ "$schemas" = "0" ]; then
    fail "no AppletCommandSchema was found under $SOURCES, so no command schema was checked."
  fi

  return "$status"
}

scratch=""

self_test() {
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/check-external-versions.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT

  local failures=0

  # expect NAME accept|reject [TEXT]. A reject must also say TEXT.
  expect() {
    local name="$1" want="$2" needle="${3:-}" got=0 output
    output="$(check_root "$scratch/case" 2>&1)" || got=$?

    if [ "$want" = "reject" ] && [ "$got" = "0" ]; then
      echo "self-test: $name was accepted" >&2
      failures=1
    elif [ "$want" = "reject" ] && [[ "$output" != *"$needle"* ]]; then
      echo "self-test: $name was rejected without \"$needle\": $output" >&2
      failures=1
    elif [ "$want" = "accept" ] && [ "$got" != "0" ]; then
      echo "self-test: $name was rejected: $output" >&2
      failures=1
    fi
  }

  # A scratch tree whose every external version is 0, with one schema.
  fresh() {
    rm -rf "$scratch/case"
    local base="$scratch/case/$SOURCES"

    mkdir -p "$base/ScriptWire" "$base/ExecDriver" "$base/ControllerPackage" \
      "$base/CJanet/include" "$base/ViewerApplet" "$scratch/case/spec"

    printf 'public enum ScriptProtocol {\n  public static let version: UInt16 = 0\n}\n' \
      >"$base/ScriptWire/ScriptProtocol.swift"
    printf 'public enum ExecProtocol {\n  public static let version = 0\n}\n' \
      >"$base/ExecDriver/ExecProtocol.swift"
    printf 'public struct ControllerDescriptor: Equatable {\n  public static let format = 0\n}\n' \
      >"$base/ControllerPackage/ControllerDescriptor.swift"
    printf '#define UNITERM_JANET_API_VERSION 0\n' >"$base/CJanet/include/uniterm_janet.h"
    printf 'let schema = AppletCommandSchema(\n  appletType: ViewerDescription.typeID, version: AppletSchemaVersion(0, 0),\n  commands: [])\n' \
      >"$base/ViewerApplet/Remote.swift"
    printf '# Declared stable versions\n\nProse.\n\n## Declared stable\n\n' >"$scratch/case/$LIST"
  }

  fresh
  expect "every version at 0" accept

  fresh
  printf 'public enum ScriptProtocol {\n  public static let version: UInt16 = 1\n}\n' \
    >"$scratch/case/$SOURCES/ScriptWire/ScriptProtocol.swift"
  expect "ScriptWire at 1" reject "ScriptProtocol.version is 1"

  fresh
  printf 'public enum ScriptProtocol {\n  public static let version: UInt16 = 15\n}\n' \
    >"$scratch/case/$SOURCES/ScriptWire/ScriptProtocol.swift"
  expect "ScriptWire at 15, named in the failure" reject "ScriptWire/ScriptProtocol.swift"

  fresh
  printf 'public enum ExecProtocol {\n  public static let version = 5\n}\n' \
    >"$scratch/case/$SOURCES/ExecDriver/ExecProtocol.swift"
  expect "the exec wire at 5" reject "ExecProtocol.version is 5"

  fresh
  printf 'public struct ControllerDescriptor: Equatable {\n  public static let format = 2\n}\n' \
    >"$scratch/case/$SOURCES/ControllerPackage/ControllerDescriptor.swift"
  expect "the descriptor format at 2" reject "ControllerDescriptor.format is 2"

  fresh
  printf '#define UNITERM_JANET_API_VERSION 1\n' >"$scratch/case/$SOURCES/CJanet/include/uniterm_janet.h"
  expect "the scripting API at 1" reject "UNITERM_JANET_API_VERSION is 1"

  fresh
  printf 'let schema = AppletCommandSchema(\n  appletType: ViewerDescription.typeID, version: AppletSchemaVersion(1, 0),\n  commands: [])\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Remote.swift"
  expect "a schema at 1.0" reject "command schema ViewerDescription.typeID is 1.0"

  fresh
  printf 'let schema = AppletCommandSchema(\n  appletType: ViewerDescription.typeID, version: AppletSchemaVersion(0, 1),\n  commands: [])\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Remote.swift"
  expect "a schema at 0.1" reject "is 0.1"

  fresh
  printf 'let schema = AppletCommandSchema(\n  appletType: ViewerDescription.typeID, version: AppletSchemaVersion(0),\n  commands: [])\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Remote.swift"
  expect "a schema written with one number at 0" accept

  fresh
  printf 'let schema = AppletCommandSchema.init(\n  appletType: ViewerDescription.typeID, version: AppletSchemaVersion(1, 0),\n  commands: [])\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Remote.swift"
  expect "an explicit init at 1.0" reject "cannot read"

  fresh
  printf 'typealias Schema = AppletCommandSchema\nlet schema = Schema(\n  appletType: ViewerDescription.typeID, version: AppletSchemaVersion(1, 0),\n  commands: [])\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Remote.swift"
  expect "a typealias that renames the schema" reject "cannot read"

  fresh
  printf 'let schema: AppletCommandSchema = .init(\n  appletType: ViewerDescription.typeID, version: AppletSchemaVersion(1, 0),\n  commands: [])\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Remote.swift"
  expect "a contextual init" reject "cannot read"

  fresh
  printf 'struct Holder {\n  let schema: AppletCommandSchema\n}\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Holder.swift"
  expect "a mere type annotation" accept

  fresh
  printf 'let schema = AppletCommandSchema(\n  appletType: ViewerDescription.typeID, version: someVersion,\n  commands: [])\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Remote.swift"
  expect "a schema whose version is not a number" reject "cannot read"

  fresh
  printf 'let a = AppletCommandSchema(\n  appletType: A.typeID, version: AppletSchemaVersion(0, 0), commands: [])\nlet b = AppletCommandSchema(\n  appletType: B.typeID, version: AppletSchemaVersion(2, 0), commands: [])\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Remote.swift"
  expect "a second schema in one file at 2.0" reject "command schema B.typeID is 2.0"

  fresh
  printf '// AppletCommandSchema(appletType: X, version: AppletSchemaVersion(9, 0))\nlet text = "AppletCommandSchema(oops"\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Notes.swift"
  expect "a schema named in a comment and a string" accept

  fresh
  printf 'public enum DocumentProtocol {\n  public static let version: UInt16 = 7\n}\nlet layoutVersion = 3\n' \
    >"$scratch/case/$SOURCES/ViewerApplet/Internal.swift"
  expect "an internal version" accept

  fresh
  printf 'public enum ScriptProtocol {\n  // version 14 once\n  public static let version: UInt16 = 0\n}\n' \
    >"$scratch/case/$SOURCES/ScriptWire/ScriptProtocol.swift"
  expect "a comment that names an old version" accept

  fresh
  printf 'public enum ScriptProtocol {\n  public static let version: UInt16 = 1\n}\n' \
    >"$scratch/case/$SOURCES/ScriptWire/ScriptProtocol.swift"
  printf -- '- `ScriptProtocol.version`\n' >>"$scratch/case/$LIST"
  expect "ScriptWire at 1 and declared stable" accept

  fresh
  printf 'public enum ScriptProtocol {\n  public static let version: UInt16 = 1\n}\n' \
    >"$scratch/case/$SOURCES/ScriptWire/ScriptProtocol.swift"
  printf -- '- `ExecProtocol.version`\n' >>"$scratch/case/$LIST"
  expect "another version declared stable" reject "ScriptProtocol.version is 1"

  fresh
  printf 'public enum ScriptProtocol {\n  public static let version: UInt16 = 1\n}\n' \
    >"$scratch/case/$SOURCES/ScriptWire/ScriptProtocol.swift"
  printf '# Declared stable versions\n\n- `ScriptProtocol.version`\n\n## Declared stable\n\n' \
    >"$scratch/case/$LIST"
  expect "a name listed above the Declared stable heading" reject "ScriptProtocol.version is 1"

  fresh
  printf 'let nothing = 1\n' >"$scratch/case/$SOURCES/ScriptWire/ScriptProtocol.swift"
  expect "a moved constant" reject "ScriptProtocol.version was not found"

  fresh
  rm "$scratch/case/$SOURCES/CJanet/include/uniterm_janet.h"
  expect "a missing header" reject "uniterm_janet.h does not exist"

  fresh
  rm "$scratch/case/$SOURCES/ViewerApplet/Remote.swift"
  expect "no schema at all" reject "no AppletCommandSchema was found"

  fresh
  rm "$scratch/case/$LIST"
  expect "a missing list reads as empty" accept

  rm -rf "$scratch/case"
  expect "a missing source tree" reject "does not exist"

  if [ "$failures" = "0" ]; then
    echo "The external version check rejects and accepts the cases it should."
  fi

  return "$failures"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if check_root "$ROOT"; then
  echo "Every external version is 0, or declared stable."
else
  exit 1
fi
