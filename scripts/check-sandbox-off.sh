#!/usr/bin/env bash
#
# Fails when the app could run inside the App Sandbox. A sandboxed app cannot give the shell its
# user's home folder, so the terminal would break.
#
# The check reads the Xcode project and any entitlements file. A built app can be checked as well:
#   scripts/check-sandbox-off.sh path/to/uniterm.app
#
# The helpers are the executables that must be sandboxed: the image decoder and the document
# decoder. Each entitlements file lives outside App/, so the check on the app stays as strict as
# before. The check also asserts that each helper holds the sandbox and no file or network
# entitlement, in the source file and in the copy inside a built app. A new sandboxed helper is
# added to HELPERS and nowhere else.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/uniterm.xcodeproj/project.pbxproj"
status=0

HELPERS="ImageDecoder DocumentDecoder"

fail() {
  echo "error: $*" >&2
  status=1
}

settings="$(grep -E 'ENABLE_APP_SANDBOX' "$PROJECT" || true)"
[ -n "$settings" ] || fail "$PROJECT does not set ENABLE_APP_SANDBOX."
if printf '%s\n' "$settings" | grep -vq 'ENABLE_APP_SANDBOX = NO;'; then
  fail "ENABLE_APP_SANDBOX is not NO everywhere in $PROJECT."
fi

if grep -rq 'com.apple.security.app-sandbox' "$ROOT/App" 2>/dev/null; then
  fail "an entitlements file under App/ turns the App Sandbox on."
fi

# Only a helper's build configurations may name an entitlements file, and each may name only its
# own. None may name a file that turns the App Sandbox on unless it belongs to its helper.
while IFS= read -r problem; do
  fail "$problem"
done < <(
  python3 -I - "$PROJECT" $HELPERS <<'PY'
import re
import sys

project = sys.argv[1]
helpers = sys.argv[2:]
text = open(project).read()
blocks = re.split(r"(?=\n\t\t[0-9A-F]{24} /\* [A-Za-z]+ \*/ = \{\n\t\t\tisa = XCBuildConfiguration;)", text)

for block in blocks:
    if "isa = XCBuildConfiguration;" not in block:
        continue
    owner = next((name for name in helpers if f"PRODUCT_NAME = {name};" in block), None)
    for value in re.findall(r"CODE_SIGN_ENTITLEMENTS = ([^;]+);", block):
        value = value.strip().strip('"')
        if owner is None:
            print(f"a build configuration outside the sandboxed helpers names {value} as its entitlements.")
        elif value != f"Helpers/{owner}/{owner}.entitlements":
            print(f"the {owner} helper names {value} as its entitlements.")
PY
)

# Entitlements that would give a helper a way to read files or reach the network.
helper_forbidden='com\.apple\.security\.(files|network|temporary-exception|inherit|device|personal-information|assets|print|automation|cs\.)'

for helper_name in $HELPERS; do
  entitlements="$ROOT/Helpers/$helper_name/$helper_name.entitlements"

  if [ ! -f "$entitlements" ]; then
    fail "$entitlements is missing."
  else
    grep -A1 'com.apple.security.app-sandbox' "$entitlements" | grep -q '<true/>' ||
      fail "the $helper_name entitlements do not set the App Sandbox to true."
    if grep -Eq "$helper_forbidden" "$entitlements"; then
      fail "the $helper_name entitlements grant file or network access."
    fi
  fi
done

if [ "$#" -ge 1 ]; then
  if codesign -d --entitlements - "$1" 2>/dev/null | grep -q 'com.apple.security.app-sandbox'; then
    fail "$1 carries the App Sandbox entitlement."
  fi

  for helper_name in $HELPERS; do
    helper="$1/Contents/Helpers/$helper_name"
    if [ ! -x "$helper" ]; then
      fail "$helper is missing from the built app."
    else
      signed="$(codesign -d --entitlements - "$helper" 2>/dev/null || true)"
      printf '%s\n' "$signed" | grep -A2 'com.apple.security.app-sandbox' | grep -q 'Bool\] true' ||
        fail "the built $helper_name does not carry the App Sandbox entitlement set to true."
      if printf '%s\n' "$signed" | grep -Eq "$helper_forbidden"; then
        fail "the built $helper_name carries a file or network entitlement."
      fi
    fi
  done
fi

if [ "$status" = "0" ]; then
  echo "The App Sandbox is off."
fi

exit "$status"
