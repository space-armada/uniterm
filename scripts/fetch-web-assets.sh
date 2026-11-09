#!/usr/bin/env bash
#
# Fetches the pinned web assets for the Markdown viewer, checks them against web-assets.pin, and
# copies the shipped files and their license notices into the repository.
#
# Usage: scripts/fetch-web-assets.sh
#
# Each npm tarball is downloaded into a fresh empty directory and checked twice: by the sha256 in the
# pin file, and by the sha512 integrity string the registry publishes. Only the shipped file and the
# license files are copied out. Run it when web-assets.pin changes, then run make licenses.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_FILE="${WEB_ASSETS_PIN_FILE:-$ROOT/web-assets.pin}"
RESOURCES="${WEB_ASSETS_RESOURCES_DIR:-$ROOT/Packages/UnitermKit/Sources/TextViewerApplet/Resources/web}"
NOTICES="${WEB_ASSETS_NOTICES_DIR:-$ROOT/ThirdParty/web}"
REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"

die() {
  echo "error: $*" >&2
  exit 1
}

# shellcheck disable=SC1090
. "$PIN_FILE"

work="$(mktemp -d "${TMPDIR:-/tmp}/uniterm-web-assets.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$RESOURCES" "$NOTICES"

# fetch NAME VERSION TARBALL_SHA256 INTEGRITY DIST DIST_SHA256 SHIPPED_NAME NOTICE_FROM NOTICE_TO...
fetch() {
  local name="$1" version="$2" tarball_sha="$3" integrity="$4" dist="$5" dist_sha="$6" shipped="$7"
  shift 7

  local dir="$work/$name"
  mkdir -p "$dir/download" "$dir/unpacked"

  curl --fail --silent --show-error --location \
    --output "$dir/download/$name-$version.tgz" "$REGISTRY/$name/-/$name-$version.tgz"

  local actual
  actual="$(shasum -a 256 "$dir/download/$name-$version.tgz" | cut -d' ' -f1)"
  [ "$actual" = "$tarball_sha" ] || die "$name $version tarball sha256 is $actual, and the pin says $tarball_sha."

  actual="sha512-$(openssl dgst -sha512 -binary "$dir/download/$name-$version.tgz" | base64)"
  [ "$actual" = "$integrity" ] || die "$name $version integrity is $actual, and the pin says $integrity."

  tar -xzf "$dir/download/$name-$version.tgz" -C "$dir/unpacked"

  actual="$(shasum -a 256 "$dir/unpacked/package/$dist" | cut -d' ' -f1)"
  [ "$actual" = "$dist_sha" ] || die "$name $version $dist sha256 is $actual, and the pin says $dist_sha."

  cp "$dir/unpacked/package/$dist" "$RESOURCES/$shipped"

  while [ "$#" -gt 0 ]; do
    cp "$dir/unpacked/package/$1" "$NOTICES/$2"
    shift 2
  done
}

fetch markdown-it "$MARKDOWN_IT_VERSION" "$MARKDOWN_IT_TARBALL_SHA256" "$MARKDOWN_IT_INTEGRITY" \
  "$MARKDOWN_IT_DIST" "$MARKDOWN_IT_SHA256" markdown-it.umd.min.js \
  LICENSE markdown-it.LICENSE

fetch dompurify "$DOMPURIFY_VERSION" "$DOMPURIFY_TARBALL_SHA256" "$DOMPURIFY_INTEGRITY" \
  "$DOMPURIFY_DIST" "$DOMPURIFY_SHA256" purify.min.js \
  LICENSE dompurify.LICENSE LICENSE-MPL dompurify.LICENSE-MPL

echo "Web assets written to $RESOURCES and $NOTICES"
