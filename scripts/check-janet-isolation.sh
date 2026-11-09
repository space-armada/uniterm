#!/usr/bin/env bash
#
# Fails when Janet can reach the app process.
#
# Janet never runs in the app. A script that exhausts memory or crashes the VM would end every
# shell in every window, so each VM lives in a helper process. Only the script helper targets may
# depend on the Janet C target, and the Xcode project may link it only into the helper commands.
#
# Usage: scripts/check-janet-isolation.sh [root]
# The optional root lets a test point the check at a scratch copy of the tree.

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
status=0

fail() {
  echo "error: $*" >&2
  status=1
}

# The targets that may name CJanet, or ScriptRuntime which carries it. A new helper is added here
# and nowhere else.
allowed_targets="CJanet ScriptRuntime ScriptHelper"

import_pattern='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*(public[[:space:]]+|package[[:space:]]+|internal[[:space:]]+|fileprivate[[:space:]]+|private[[:space:]]+)?(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(struct[[:space:]]+|class[[:space:]]+|enum[[:space:]]+|func[[:space:]]+|var[[:space:]]+|let[[:space:]]+|typealias[[:space:]]+|protocol[[:space:]]+)?(CJanet|ScriptRuntime)([[:space:].]|$)'

allowed_dirs=(
  "Packages/UnitermKit/Sources/CJanet"
  "Packages/UnitermKit/Sources/ScriptRuntime"
  "Packages/UnitermKit/Sources/ScriptHelper"
  "Helpers/UnitermCLI"
)

while IFS= read -r file; do
  relative="${file#"$ROOT"/}"

  allowed=0
  for dir in "${allowed_dirs[@]}"; do
    case "$relative" in
    "$dir"/*) allowed=1 ;;
    esac
  done

  if [ "$allowed" = "0" ]; then
    fail "$relative imports Janet. Only the script helper targets may."
  fi
done < <(grep -rlE "$import_pattern" "$ROOT/App" "$ROOT/Helpers" "$ROOT/UITests" "$ROOT/Packages/UnitermKit/Sources" "$ROOT/Packages/UnitermKit/Tests" --include='*.swift' 2>/dev/null || true)

manifest="$ROOT/Packages/UnitermKit/Package.swift"
if [ -f "$manifest" ]; then
  while IFS= read -r line; do
    fail "Package.swift lets $line"
  done < <(
    python3 -I - "$manifest" $allowed_targets <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
allowed = set(sys.argv[2:])
forbidden = ("CJanet", "ScriptRuntime", "ScriptHelper")

for match in re.finditer(r"\.(target|testTarget|executableTarget)\(\s*name:\s*\"([A-Za-z0-9_]+)\"", text):
    name = match.group(2)
    start = match.start()
    depth = 0
    end = start
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                end = index
                break
    body = text[start:end]
    dependencies = re.search(r"dependencies:\s*\[([^\]]*)\]", body)
    names = re.findall(r"\"([A-Za-z0-9_]+)\"", dependencies.group(1)) if dependencies else []
    if name in allowed:
        continue
    for dependency in names:
        if dependency in forbidden and not name.endswith("Tests"):
            print(f"{name} depend on {dependency}. Only the script helper targets may depend on Janet.")
PY
  )

  # The script host is the app side, so it and the wire may never reach Janet, even through tests.
  for target in ScriptHost ScriptWire; do
    if python3 -I - "$manifest" "$target" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
target = sys.argv[2]
match = re.search(r"\.target\(\s*name:\s*\"" + target + r"\"[^)]*\)", text)
body = match.group(0) if match else ""
sys.exit(0 if re.search(r"CJanet|ScriptRuntime", body) else 1)
PY
    then
      fail "Package.swift makes $target depend on Janet."
    fi
  done
fi

# In the Xcode project, only the helper command may link ScriptRuntime. The app links ScriptHost.
project="$ROOT/uniterm.xcodeproj/project.pbxproj"

read -r -d '' project_check <<'PY' || true
import re
import sys

text = open(sys.argv[1]).read()
forbidden = {"CJanet", "ScriptRuntime", "ScriptHelper"}
products = {}
product_pattern = r"\t\t([0-9A-F]{24}) /\* ([A-Za-z]+) \*/ = \{\n\t\t\tisa = XCSwiftPackageProductDependency;"

for match in re.finditer(product_pattern, text):
    products[match.group(1)] = match.group(2)

target_pattern = r"\t\t[0-9A-F]{24} /\* [^*]+ \*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?\n\t\t\};"
dependency_pattern = r"packageProductDependencies = \((.*?)\);"

for match in re.finditer(target_pattern, text, re.S):
    body = match.group(0)
    name = re.search(r"\n\t\t\tname = ([^;]+);", body).group(1).strip('"')
    section = re.search(dependency_pattern, body, re.S)
    ids = re.findall(r"([0-9A-F]{24})", section.group(1)) if section else []
    for identifier in ids:
        product = products.get(identifier)
        if product in forbidden and name != "UnitermCLI":
            print("the " + name + " target links " + product + ". Only the UnitermCLI target may.")
PY

if [ -f "$project" ]; then
  while IFS= read -r problem; do
    fail "$problem"
  done < <(python3 -I -c "$project_check" "$project")
fi

if [ "$status" = "0" ]; then
  echo "Janet is reachable only from the script helper targets."
fi

exit "$status"
