#!/bin/bash
#
# Verifies that ScribbleEverywhereCore stays portable: it must not import any Apple UI
# framework, and it must build on its own.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/Sources/ScribbleEverywhereCore"

echo "==> Checking ScribbleEverywhereCore for platform-specific imports"
FORBIDDEN='AppKit|Cocoa|CoreGraphics|QuartzCore|ScreenCaptureKit|Carbon|SwiftUI|CoreImage|ImageIO|UniformTypeIdentifiers'
if grep -REn "^[[:space:]]*import[[:space:]]+($FORBIDDEN)" "$CORE"; then
    echo "error: ScribbleEverywhereCore must use Foundation only" >&2
    exit 1
fi
echo "    OK: Foundation only"

echo "==> Building ScribbleEverywhereCore"
swift build --target ScribbleEverywhereCore --package-path "$ROOT"

echo "==> Done"
