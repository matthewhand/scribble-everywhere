#!/usr/bin/env bash
# Validate the host shell without installing it or changing user preferences.
set -euo pipefail
cd "$(dirname "$0")/.."

extra=(--package-path "$PWD")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch-path)
      [[ $# -ge 2 ]] || { echo "--scratch-path requires a directory" >&2; exit 2; }
      extra+=(--scratch-path "$2"); shift 2 ;;
    *) echo "usage: bash scripts/validate-native.sh [--scratch-path DIRECTORY]" >&2; exit 2 ;;
  esac
done

case "$(uname -s)" in
  Darwin) product=PalimpsestInk; suite=PalimpsestMacTests ;;
  Linux)
    product=palimpsest-ink; suite=PalimpsestLinuxTests
    bash scripts/gen-wayland-protocols.sh ;;
  *) echo "Use scripts/build-windows.ps1 -RunTests on Windows." >&2; exit 2 ;;
esac

test_command=(swift test)
test_help=$(swift test --help)
if [[ "$test_help" == *--build-system* ]]; then test_command+=(--build-system native); fi
tests=$("${test_command[@]}" "${extra[@]}" --jobs 2 -c release list)
if ! grep -q 'PalimpsestCoreTests\.' <<< "$tests" || ! grep -q "$suite\." <<< "$tests"; then
  echo "Test discovery must find both Core and $suite cases." >&2
  exit 1
fi
printf '%s\n' "$tests"
"${test_command[@]}" "${extra[@]}" --jobs 2 -c release
swift build "${extra[@]}" --jobs 2 -c release --product "$product"
if [[ "$product" == palimpsest-ink ]]; then
  bin_dir=$(swift build "${extra[@]}" -c release --show-bin-path)
  "$bin_dir/palimpsest-ink" self-test
fi
