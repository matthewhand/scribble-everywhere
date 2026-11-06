#!/bin/bash
#
# Keeps the version in one place. PalimpsestCore/PalimpsestCore/Version.swift is
# the source of truth; Info.plist must agree with it, or a macOS build reports a
# different version from `palimpsestctl version`.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_SWIFT="$ROOT/Sources/ScribbleEverywhereCore/Version.swift"
PLIST="$ROOT/Info.plist"

CORE_VERSION="$(sed -n 's/.*static let short = "\([^"]*\)".*/\1/p' "$VERSION_SWIFT")"
if [ -z "$CORE_VERSION" ]; then
    echo "error: could not read the version from $VERSION_SWIFT" >&2
    exit 1
fi

PLIST_VERSION="$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;}' "$PLIST")"

echo "==> Core version:  $CORE_VERSION"
echo "==> Info.plist:    $PLIST_VERSION"
if [ "$CORE_VERSION" != "$PLIST_VERSION" ]; then
    echo "error: version mismatch — update Info.plist or Version.swift" >&2
    exit 1
fi
echo "    OK: versions agree"
