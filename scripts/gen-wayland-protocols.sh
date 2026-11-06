#!/usr/bin/env bash
# Generates the Wayland protocol C code the Linux shell binds against.
# Core Wayland types come from libwayland. This generates wlr-layer-shell,
# tablet-unstable-v2, and xdg-shell (layer-shell's generated types table
# references xdg_popup_interface).
set -euo pipefail
cd "$(dirname "$0")/.."

scanner="${WAYLAND_SCANNER:-$(command -v wayland-scanner || true)}"
if [[ -z "$scanner" ]]; then
  echo "wayland-scanner not found (install the wayland package)" >&2
  exit 1
fi

out="Sources/CScribbleEverywhereLinux/Generated"
mkdir -p "$out"

layer_xml() {
  local vendored="scripts/protocols/wlr-layer-shell-unstable-v1.xml"
  if [[ -f "$vendored" ]]; then
    echo "$vendored"
    return
  fi
  for p in \
    "/usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml" \
    "/usr/share/wayland-protocols/unstable/wlr-layer-shell-unstable-v1.xml"; do
    [[ -f "$p" ]] && { echo "$p"; return; }
  done
  local tmp
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" \
    "https://raw.githubusercontent.com/swaywm/wlr-protocols/master/unstable/wlr-layer-shell-unstable-v1.xml"
  echo "$tmp"
}

tablet_xml() {
  for p in \
    "/usr/share/wayland-protocols/unstable/tablet/tablet-unstable-v2.xml"; do
    [[ -f "$p" ]] && { echo "$p"; return; }
  done
  local tmp
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" \
    "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/raw/main/unstable/tablet/tablet-unstable-v2.xml"
  echo "$tmp"
}

xdg_xml() {
  for p in \
    "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"; do
    [[ -f "$p" ]] && { echo "$p"; return; }
  done
  local tmp
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" \
    "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/raw/main/stable/xdg-shell/xdg-shell.xml"
  echo "$tmp"
}

layer=$(layer_xml)
tablet=$(tablet_xml)
xdg=$(xdg_xml)

"$scanner" client-header "$layer" "$out/wlr-layer-shell-unstable-v1.h"
"$scanner" private-code "$layer" "$out/wlr-layer-shell-unstable-v1.c"
"$scanner" client-header "$tablet" "$out/tablet-unstable-v2.h"
"$scanner" private-code "$tablet" "$out/tablet-unstable-v2.c"
"$scanner" client-header "$xdg" "$out/xdg-shell.h"
"$scanner" private-code "$xdg" "$out/xdg-shell.c"

echo "Generated wayland protocol code in $out"
