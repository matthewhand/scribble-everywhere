#!/usr/bin/env bash
# Archive a locally built app; does not sign for distribution or notarize it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$HOME/Library/Application Support/PalimpsestInk/PalimpsestInk.app"
output="$root/.build/artifacts"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) [[ $# -ge 2 ]] || exit 2; app="$2"; shift 2 ;;
    --output-dir) [[ $# -ge 2 ]] || exit 2; output="$2"; shift 2 ;;
    *) echo "usage: $0 [--app APP_BUNDLE] [--output-dir DIRECTORY]" >&2; exit 2 ;;
  esac
done
if [[ "$(uname -s)" != Darwin ]]; then echo "Package on macOS." >&2; exit 1; fi
[[ -f "$app/Contents/Info.plist" && -x "$app/Contents/MacOS/PalimpsestInk" ]] || {
  echo "App bundle missing or incomplete; run scripts/make-app.sh first: $app" >&2; exit 1;
}
codesign --verify --strict "$app"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/scribbleeverywhere-package.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
ditto "$app" "$scratch/ScribbleEverywhere.app"
codesign --verify --strict "$scratch/ScribbleEverywhere.app"
archive="$output/ScribbleEverywhere-macos-$(uname -m).zip"
ditto -c -k --sequesterRsrc --keepParent "$scratch/ScribbleEverywhere.app" "$archive"
(cd "$output" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "Experimental macOS archive: $archive"
echo "A locally signed app is not a notarized distribution release."
