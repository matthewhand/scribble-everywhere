#!/bin/bash
#
# Build (if needed) and launch ScribbleEverywhere.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Library/Application Support/PalimpsestInk/PalimpsestInk.app"

if [ "${1:-}" = "--build" ] || [ ! -x "$APP/Contents/MacOS/PalimpsestInk" ]; then
    "$ROOT/scripts/make-app.sh" release
else
    echo "==> Reusing existing build (use ./run.sh --build to rebuild)"
fi

echo "==> Launching ScribbleEverywhere"
open "$APP"
