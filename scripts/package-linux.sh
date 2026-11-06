#!/usr/bin/env bash
# Package the current Linux build without installing it or modifying user data.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
binary=""
output="$root/.build/artifacts"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) [[ $# -ge 2 ]] || exit 2; binary="$2"; shift 2 ;;
    --output-dir) [[ $# -ge 2 ]] || exit 2; output="$2"; shift 2 ;;
    *) echo "usage: $0 [--binary EXECUTABLE] [--output-dir DIRECTORY]" >&2; exit 2 ;;
  esac
done
if [[ "$(uname -s)" != Linux ]]; then echo "Package on Linux." >&2; exit 1; fi
if [[ -z "$binary" ]]; then
  bash scripts/gen-wayland-protocols.sh
  swift build -c release --product palimpsest-ink
  bin_dir=$(swift build -c release --show-bin-path)
  binary="$bin_dir/palimpsest-ink"
fi
[[ -f "$binary" && -x "$binary" ]] || { echo "Executable missing: $binary" >&2; exit 1; }
mkdir -p "$output"
output="$(cd "$output" && pwd)"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/scribbleeverywhere-package.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
bundle="$scratch/ScribbleEverywhere"
mkdir -p "$bundle/bin" "$bundle/share/omarchy/matthewh.palimpsest-ink"
install -m 755 "$binary" "$bundle/bin/scribbleeverywhere"
for alias in scribbleeverywherectl palimpsest-ink palimpsestctl; do
  ln -s scribbleeverywhere "$bundle/bin/$alias"
done
cp packaging/omarchy/matthewh.palimpsest-ink/{manifest.json,BarWidget.qml} "$bundle/share/omarchy/matthewh.palimpsest-ink/"
cp LICENSE "$bundle/LICENSE"
cat > "$bundle/README.txt" <<'EOF'
ScribbleEverywhere for Omarchy / Hyprland (experimental)

This archive does not install itself. Its executable requires compatible Swift
runtime and system libraries, Wayland, Hyprland, grim, wl-copy and wtype.
The optional bar widget is in share/omarchy. Existing Palimpsest Ink settings
and saved annotations remain in their legacy locations.
The package has not been validated on a clean machine.
EOF
archive="$output/ScribbleEverywhere-linux-$(uname -m).tar.gz"
tar -C "$scratch" -czf "$archive" ScribbleEverywhere
(cd "$output" && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "Experimental Linux archive: $archive"
