#!/usr/bin/env bash
#
# Collects the license notices that ship in the app, into Licenses/ at the repo root.
#
# Usage: scripts/collect-licenses.sh
#
# The notices come from five places:
#   - Ghostty's own LICENSE, its bundled font notices, and its vendored nerd-fonts notice. They are
#     read from the pinned source tarball in the Ghostty cache.
#   - Every Zig package that the pinned Ghostty build fetched, from the kept package cache. These
#     are the libraries that end up linked or bundled. A package that carries no license file is
#     named in Licenses/README.txt.
#   - Every Swift package that Packages/UnitermKit/Package.resolved pins, from its resolved checkout
#     under .build/SourcePackages or .build/swiftpm. The checkout must be at the pinned revision.
#   - The web assets the Markdown viewer bundles, markdown-it and DOMPurify. Their notices are kept in
#     ThirdParty/web, and the shipped files are checked against web-assets.pin first.
#   - Catppuccin, whose palette uniterm uses.
#
# Rerun it when ghostty.pin changes, and commit the result. The Xcode build copies Licenses/ into
# Contents/Resources/Licenses.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_FILE="${GHOSTTY_PIN_FILE:-$ROOT/ghostty.pin}"
CACHE="${GHOSTTY_CACHE_DIR:-$ROOT/.cache/ghostty}"
OUT="${LICENSES_DIR:-$ROOT/Licenses}"
SWIFT_PINS="${SWIFTPM_PINS_FILE:-$ROOT/Packages/UnitermKit/Package.resolved}"
SWIFT_CHECKOUTS="${SWIFTPM_CHECKOUTS_DIRS:-$ROOT/.build/SourcePackages/checkouts:$ROOT/.build/swiftpm/checkouts}"
WEB_PIN="${WEB_ASSETS_PIN_FILE:-$ROOT/web-assets.pin}"
WEB_NOTICES="${WEB_ASSETS_NOTICES_DIR:-$ROOT/ThirdParty/web}"
WEB_RESOURCES="${WEB_ASSETS_RESOURCES_DIR:-$ROOT/Packages/UnitermKit/Sources/TextViewerApplet/Resources/web}"

die() {
  echo "error: $*" >&2
  exit 1
}

# shellcheck disable=SC1090
. "$PIN_FILE"

tarball="$CACHE/dl/$GHOSTTY_COMMIT.tar.gz"
[ -f "$tarball" ] || die "the Ghostty source is not cached. Run make build first."
[ -d "$CACHE/zig-global/p" ] || die "the Zig package cache is missing. Run make build first."
[ -f "$SWIFT_PINS" ] || die "$SWIFT_PINS is missing."
[ -f "$WEB_PIN" ] || die "$WEB_PIN is missing."

work="$(mktemp -d "${TMPDIR:-/tmp}/uniterm-licenses.XXXXXX")"
trap 'rm -rf "$work"' EXIT

tar -xzf "$tarball" -C "$work" --strip-components=1 \
  --exclude='.gitmodules' --exclude='.gitattributes' --exclude='.gitignore' --exclude='.git'

python3 -I - "$work" "$CACHE/zig-global/p" "$OUT" "$GHOSTTY_TAG" "$SWIFT_PINS" "$SWIFT_CHECKOUTS" \
  "$WEB_PIN" "$WEB_NOTICES" "$WEB_RESOURCES" <<'PY'
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile

source, packages, out, tag, swift_pins, swift_checkouts, web_pin, web_notices, web_resources = sys.argv[1:10]

LICENSE_NAME = re.compile(r"^(licen[sc]e|copying|copyright|notice|unlicense|ofl)([-_.].*)?$", re.I)

# The Swift packages are checked before anything is wiped, so a missing or stale checkout leaves the
# existing notices alone. A checkout that is not at the pinned revision would ship another version's notice.
def package_license_files(root):
    return sorted(
        os.path.join(root, name)
        for name in os.listdir(root)
        if LICENSE_NAME.match(name) and os.path.isfile(os.path.join(root, name))
    )


swift_sources = []
swift_packages = []
with open(swift_pins) as handle:
    pins = json.load(handle)["pins"]

for pin in sorted(pins, key=lambda entry: entry["identity"]):
    repository = pin["location"].rstrip("/").split("/")[-1]
    if repository.endswith(".git"):
        repository = repository[:-4]
    revision = pin["state"]["revision"]

    checkout = None
    for folder in swift_checkouts.split(":"):
        candidate = os.path.join(folder, repository)
        if os.path.isdir(candidate):
            checkout = candidate
            break
    if checkout is None:
        sys.exit("error: no checkout of %s under %s. Run make build first." % (repository, swift_checkouts))

    head = subprocess.run(
        ["git", "-C", checkout, "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    ).stdout.strip()
    if head != revision:
        sys.exit("error: the checkout of %s is at %s, and Package.resolved pins %s." % (repository, head, revision))

    files = package_license_files(checkout)
    if not files:
        sys.exit("error: the checkout of %s has no license file." % repository)

    swift_sources.append((repository, checkout, files))
    swift_packages.append((repository, pin["state"].get("version", revision[:12])))

# The web assets are checked before anything is wiped too. A shipped file that no longer matches its
# pin would carry a notice for another build.
web_values = {}
with open(web_pin) as handle:
    for line in handle:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            web_values[key] = value

web_assets = [
    ("markdown-it", web_values["MARKDOWN_IT_VERSION"], "markdown-it.umd.min.js", web_values["MARKDOWN_IT_SHA256"],
     [("markdown-it.LICENSE", "LICENSE")]),
    ("DOMPurify", web_values["DOMPURIFY_VERSION"], "purify.min.js", web_values["DOMPURIFY_SHA256"],
     [("dompurify.LICENSE", "LICENSE"), ("dompurify.LICENSE-MPL", "LICENSE-MPL")]),
]

for name, version, shipped, digest, notices in web_assets:
    with open(os.path.join(web_resources, shipped), "rb") as handle:
        actual = hashlib.sha256(handle.read()).hexdigest()
    if actual != digest:
        sys.exit("error: %s is %s, and web-assets.pin pins %s for %s %s." % (shipped, actual, digest, name, version))
    for source_name, _ in notices:
        if not os.path.isfile(os.path.join(web_notices, source_name)):
            sys.exit("error: %s has no notice %s in %s." % (name, source_name, web_notices))

shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)


def copy(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)


def license_files(root, depth=2):
    found = []
    for current, dirs, files in os.walk(root):
        level = current[len(root):].count(os.sep)
        if level >= depth:
            dirs[:] = []
        for name in sorted(files):
            if LICENSE_NAME.match(name):
                found.append(os.path.join(current, name))
    return sorted(found)


# The system Python predates tarfile's extraction filters. Only regular files and folders inside
# the package's own top folder are unpacked, which is all a license search reads.
def unpack_package(path, package, destination):
    with tarfile.open(path) as archive:
        for member in archive.getmembers():
            name = os.path.normpath(member.name)
            if os.path.isabs(name) or name.split(os.sep)[0] != package or ".." in name.split(os.sep):
                sys.exit("error: %s holds an unexpected path %s." % (path, member.name))

            if member.isdir():
                os.makedirs(os.path.join(destination, name), exist_ok=True)
            elif member.isfile():
                target = os.path.join(destination, name)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with archive.extractfile(member) as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)


copy(os.path.join(source, "LICENSE"), os.path.join(out, "Ghostty", "LICENSE"))
copy(
    os.path.join(source, "vendor", "nerd-fonts", "LICENSE"),
    os.path.join(out, "Ghostty", "vendor-nerd-fonts-LICENSE"),
)

fonts = os.path.join(source, "src", "font", "res")
for name in sorted(os.listdir(fonts)):
    if name.endswith(".txt"):
        copy(os.path.join(fonts, name), os.path.join(out, "Ghostty", "fonts", name))

names = {}
with open(os.path.join(source, "build.zig.zon.json")) as handle:
    for key, value in json.load(handle).items():
        names[key] = value["name"]

# Zig 0.16 and later keep each package as a .tar.gz of one top folder named for the package hash.
# Older Zig kept that folder unpacked. The archives are unpacked here, so both read the same way.
#
# The package cache keeps every package any earlier pin fetched. Only the packages that the
# pinned source's build.zig.zon.json names belong to this build.
unpacked = os.path.join(source, ".zig-packages")
roots = {}
for entry in sorted(os.listdir(packages)):
    path = os.path.join(packages, entry)
    package = entry[: -len(".tar.gz")] if entry.endswith(".tar.gz") else entry
    if package not in names:
        continue

    if os.path.isdir(path):
        roots[package] = path
    elif entry.endswith(".tar.gz"):
        unpack_package(path, package, unpacked)
        roots[package] = os.path.join(unpacked, package)

if not roots:
    sys.exit("error: the Zig package cache at %s holds no packages. Run make build first." % packages)

without_license = []
for entry, root in sorted(roots.items()):
    if not os.path.isdir(root):
        sys.exit("error: the Zig package archive for %s has no %s folder." % (entry, entry))

    name = names[entry]
    files = license_files(root)
    if not files:
        without_license.append(name)
        continue

    for path in files:
        relative = os.path.relpath(path, root).replace(os.sep, "__")
        copy(path, os.path.join(out, "ghostty-dependencies", name, relative))

for repository, checkout, files in swift_sources:
    for path in files:
        copy(path, os.path.join(out, "swift-packages", repository, os.path.basename(path)))

for name, version, shipped, digest, notices in web_assets:
    for source_name, target_name in notices:
        copy(os.path.join(web_notices, source_name), os.path.join(out, "web-assets", name, target_name))

catppuccin = """MIT License

Copyright (c) 2021 Catppuccin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
os.makedirs(os.path.join(out, "Catppuccin"))
with open(os.path.join(out, "Catppuccin", "LICENSE"), "w") as handle:
    handle.write(catppuccin)

lines = [
    "License notices for the software that uniterm ships.",
    "",
    "Ghostty/                  Ghostty %s and its bundled font notices" % tag,
    "ghostty-dependencies/     the libraries that Ghostty's build fetched, one folder each",
    "swift-packages/           the Swift packages that uniterm pins, one folder each",
    "web-assets/               the parser and sanitizer that the Markdown viewer bundles",
    "Catppuccin/               the Catppuccin color palette",
    "",
]
if swift_packages:
    lines.append("The Swift packages are:")
    lines.extend("  %s %s" % package for package in swift_packages)
    lines.append("")
lines.append("The web assets are:")
lines.extend("  %s %s" % (name, version) for name, version, _, _, _ in web_assets)
lines.append("")
if without_license:
    lines.append("These packages carry no license file in the fetched source. See their upstream projects:")
    lines.extend("  " + name for name in sorted(set(without_license)))
    lines.append("")

with open(os.path.join(out, "README.txt"), "w") as handle:
    handle.write("\n".join(lines))
PY

echo "Licenses written to $OUT"
