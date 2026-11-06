#!/usr/bin/env bash
# Exercise archive contents without a Swift toolchain or a live desktop.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/scribbleeverywhere-package-check.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
fixture="$scratch/fixture"
printf '#!/bin/sh\nprintf "fixture-ok\\n"\n' > "$fixture"
chmod +x "$fixture"
bash "$root/scripts/package-linux.sh" --binary "$fixture" --output-dir "$scratch/output"
archive="ScribbleEverywhere-linux-$(uname -m).tar.gz"
(cd "$scratch/output" && sha256sum -c "$archive.sha256")
mkdir "$scratch/extracted"
tar -xzf "$scratch/output/$archive" -C "$scratch/extracted"
bundle="$scratch/extracted/ScribbleEverywhere"
cmp "$fixture" "$bundle/bin/scribbleeverywhere"
for alias in scribbleeverywherectl palimpsest-ink palimpsestctl; do
  [[ -L "$bundle/bin/$alias" && "$(readlink "$bundle/bin/$alias")" == scribbleeverywhere ]]
  [[ "$("$bundle/bin/$alias")" == fixture-ok ]]
done
cmp "$root/LICENSE" "$bundle/LICENSE"
for file in manifest.json BarWidget.qml; do
  cmp "$root/packaging/omarchy/matthewh.palimpsest-ink/$file" "$bundle/share/omarchy/matthewh.palimpsest-ink/$file"
done
chmod -x "$fixture"
if bash "$root/scripts/package-linux.sh" --binary "$fixture" --output-dir "$scratch/invalid"; then
  echo "Packaging accepted a non-executable input" >&2; exit 1
fi
echo "Archive contents, command aliases, checksum and input validation passed."
