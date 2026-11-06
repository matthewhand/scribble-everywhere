#!/usr/bin/env bash
# Installs a udev uaccess tag so ScribbleEverywhere can read the Surface Pen
# barrel while the overlay is hidden. Needs root once.
set -euo pipefail
cd "$(dirname "$0")/.."

rule_src="packaging/linux/69-palimpsest-ink-stylus.rules"
rule_dst="/etc/udev/rules.d/69-palimpsest-ink-stylus.rules"

if [[ ! -f "$rule_src" ]]; then
  echo "missing $rule_src" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  self="$(readlink -f "$0")"
  if [[ -t 0 ]]; then
    exec sudo "$self" "$@"
  fi
  if command -v pkexec >/dev/null && pgrep -u "${USER:-$(id -un)}" -f 'polkit.*agent' >/dev/null; then
    exec pkexec "$self" "$@"
  fi
  exec sudo "$self" "$@"
fi

install -m 644 "$rule_src" "$rule_dst"
udevadm control --reload-rules
udevadm trigger --subsystem-match=input --action=change

target_user="${SUDO_USER:-}"
if [[ -z "$target_user" && -n "${PKEXEC_UID:-}" && "$PKEXEC_UID" != "0" ]]; then
  target_user="$(getent passwd "$PKEXEC_UID" | cut -d: -f1 || true)"
fi
if [[ -n "$target_user" && "$target_user" != "root" ]]; then
  for namefile in /sys/class/input/event*/device/name; do
    [[ -f "$namefile" ]] || continue
    name="$(cat "$namefile" 2>/dev/null || true)"
    case "$name" in
      "IPTSD Virtual Stylus "*)
        event="$(basename "$(dirname "$(dirname "$namefile")")")"
        node="/dev/input/$event"
        if command -v setfacl >/dev/null; then
          setfacl -m "u:${target_user}:rw" "$node" || true
        fi
        echo "tagged $node ($name)"
        ;;
    esac
  done
fi

echo "Installed $rule_dst"
echo "Restart palimpsest-ink after this: palimpsestctl quit && palimpsest-ink daemon"
