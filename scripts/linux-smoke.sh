#!/usr/bin/env bash
# Exercises the running Linux shell: socket, overlay, a synthetic stroke,
# grim capture, a PNG on the clipboard, menu JSON, and the delivery action.
# Needs a Hyprland session.
set -euo pipefail
cd "$(dirname "$0")/.."

ctl="${HOME}/.local/bin/palimpsestctl"
if [[ ! -x "$ctl" && -x .build/release/palimpsest-ink ]]; then
  ctl=".build/release/palimpsest-ink"
fi

echo "self-test"
"$ctl" self-test

echo "status"
initial_status=$("$ctl" status)
echo "$initial_status"
if [[ "$initial_status" != *"annotating=false"* || "$initial_status" != *"strokes=0 "* ]]; then
  echo "Smoke validation requires an idle, empty canvas; existing ink is preserved." >&2
  exit 1
fi
original_action=$("$ctl" action)
original_action=${original_action#ok action=}
original_save=$("$ctl" save-annotations)
original_save=${original_save#ok save-annotations=}
case "$original_action" in clipboard|copyAndPaste) ;; *) exit 1 ;; esac
case "$original_save" in on|off) ;; *) exit 1 ;; esac
cleanup() {
  "$ctl" cancel >/dev/null || true
  "$ctl" clear >/dev/null || true
  "$ctl" action "$original_action" >/dev/null || true
  "$ctl" save-annotations "$original_save" >/dev/null || true
}
trap cleanup EXIT
"$ctl" save-annotations off

echo "toggle on"
"$ctl" toggle

python3 - <<'PY'
import json, subprocess, sys
layers = json.loads(subprocess.check_output(["hyprctl", "layers", "-j"]))
found = False
for monitor in layers.values():
    levels = monitor.get("levels", {})
    for entries in levels.values():
        for entry in entries:
            if entry.get("namespace") == "palimpsest-ink":
                print(f"overlay {entry.get('w')}x{entry.get('h')} at {entry.get('x')},{entry.get('y')}")
                found = True
if not found:
    sys.exit("palimpsest-ink layer was not mapped")
PY

echo "draw + copy"
"$ctl" draw 80,80 400,220
"$ctl" copy

python3 - <<'PY'
import subprocess, sys, zlib, struct
raw = subprocess.check_output(["wl-paste", "-t", "image/png"])
if raw[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("clipboard is not a PNG")
# Validate every chunk and inflate the complete libpng RGBA8 raster.
offset = 8
width = height = None
compressed = bytearray()
ended = False
while offset + 8 <= len(raw):
    length = struct.unpack(">I", raw[offset:offset+4])[0]
    kind = raw[offset+4:offset+8]
    if offset + 12 + length > len(raw):
        sys.exit("PNG chunk truncated")
    chunk = raw[offset+8:offset+8+length]
    crc = struct.unpack(">I", raw[offset+8+length:offset+12+length])[0]
    if zlib.crc32(kind + chunk) & 0xffffffff != crc:
        sys.exit("PNG chunk CRC failed")
    if kind == b"IHDR":
        if len(chunk) != 13 or chunk[8:10] != bytes([8, 6]):
            sys.exit("Expected an RGBA8 PNG")
        width, height = struct.unpack(">II", chunk[:8])
    if kind == b"IDAT":
        compressed.extend(chunk)
    offset += 12 + length
    if kind == b"IEND":
        ended = True
        break
print(f"clipboard PNG {width}x{height} ({len(raw)} bytes)")
if not width or not height or not ended:
    sys.exit("PNG missing IHDR/IEND")
if len(zlib.decompress(compressed)) != height * (1 + width * 4):
    sys.exit("PNG raster length mismatch")
PY

echo "status after copy"
"$ctl" status

echo "menu JSON"
"$ctl" menu | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    obj = json.loads(raw)
except json.JSONDecodeError as e:
    sys.exit("menu is not JSON: %s" % e)
if not isinstance(obj, dict):
    sys.exit("menu JSON is not an object")
required = ["action", "pasteShown", "extras", "folder"]
missing = [key for key in required if key not in obj]
if missing:
    sys.exit("menu JSON missing keys: " + ", ".join(missing))
if "hotkey" not in obj:
    print("menu JSON ok (hotkey not present yet)")
else:
    print("menu JSON ok (hotkey present)")
'

echo "action round-trip"
reply=$("$ctl" action copy-and-paste)
echo "$reply"
[[ "$reply" == "ok action=copyAndPaste" ]]
reply=$("$ctl" action clipboard)
echo "$reply"
clipboard_ok=0
if [[ "$reply" == "ok action=clipboard" ]]; then
  clipboard_ok=1
fi
# Restore the user's actual action, including clipboard-only preferences.
reply=$("$ctl" action "$original_action")
echo "restored $reply"
[[ "$clipboard_ok" -eq 1 ]]
[[ "$reply" == "ok action=$original_action" ]]

echo "smoke ok"
