#!/bin/bash
#
# Assembles build/PalimpsestInk.app from the SwiftPM executable.
#
# Usage: scripts/make-app.sh [debug|release]   (default: release)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
# Documents is synced by iCloud FileProvider, which re-stamps FinderInfo xattrs
# codesign refuses to sign over. Stage the finished bundle outside the sync.
STAGE="$HOME/Library/Application Support/PalimpsestInk"
APP="$STAGE/PalimpsestInk.app"
BUNDLE_ID="dev.matthewhand.palimpsest"

echo "==> Building Palimpsest Ink ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
BIN="$BIN_DIR/PalimpsestInk"
if [ ! -x "$BIN" ]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PalimpsestInk"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Strip extended attributes; codesign rejects "resource fork / Finder info".
xattr -cr "$APP" 2>/dev/null || true

# Prefer the stable local identity: TCC keeps its grants across rebuilds.
# Ad-hoc (-) changes the cdhash every build and silently voids granted
# permissions (scripts/make-signing-cert.sh creates the identity once).
IDENTITY="Palimpsest Ink"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1
else
    echo "warning: no stable signing identity; run scripts/make-signing-cert.sh once." >&2
    echo "         Falling back to ad-hoc signing (TCC will re-prompt each build)." >&2
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true
fi
codesign --verify "$APP" || echo "warning: codesign --verify failed" >&2

echo "==> Done: $APP"
echo "    Run with: open \"$APP\""
