#!/usr/bin/env bash
# Builds the Linux shell of ScribbleEverywhere.
#
# Needs: a Swift toolchain, wayland-scanner, libwayland (client + cursor),
# libpng, grim, wl-clipboard, wtype, and hyprctl on a Hyprland session.
#
#   ./scripts/build-linux.sh            build and install ~/.local/bin/scribble
#   ./scripts/build-linux.sh --applet   also install the optional Omarchy bar widget
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -d "${HOME}/.local/lib/swift-compat" ]]; then
  export LD_LIBRARY_PATH="${HOME}/.local/lib/swift-compat${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
if command -v mise >/dev/null && mise which swift >/dev/null 2>&1; then
  eval "$(mise activate bash --shims)"
fi
if [[ -x "${HOME}/.local/share/swift/usr/bin/swift" ]]; then
  export PATH="${HOME}/.local/share/swift/usr/bin:${PATH}"
fi

applet=0
for arg in "$@"; do
  case "$arg" in
    --applet) applet=1 ;;
    -h|--help)
      echo "usage: scripts/build-linux.sh [--applet]"
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if ! command -v swift >/dev/null; then
  echo "swift not found. Install a Swift toolchain and re-run." >&2
  exit 1
fi

./scripts/gen-wayland-protocols.sh
swift build -c release --product scribble

install -Dm755 ".build/release/scribble" "${HOME}/.local/bin/scribble"
ln -sfn "${HOME}/.local/bin/scribble" "${HOME}/.local/bin/scribblectl"

echo "Installed ${HOME}/.local/bin/scribble"
echo "Control client: scribblectl (starts the daemon on first use)"
echo
echo "Hyprland bind (one global chord; Esc / Ctrl+Z work while annotating):"
echo '  o.bind("SUPER + ALT + D", "ScribbleEverywhere", "scribblectl toggle")'
echo
echo "Surface Pen barrel start (once, needs root) so the button works with the overlay hidden:"
echo '  ./scripts/install-linux-stylus-access.sh'
echo
echo "Autostart, if you want the daemon before the first click:"
echo '  o.exec_on_start(os.getenv("HOME") .. "/.local/bin/scribble daemon")'

if [[ "$applet" == 1 ]]; then
  ./scripts/install-omarchy-applet.sh
fi
