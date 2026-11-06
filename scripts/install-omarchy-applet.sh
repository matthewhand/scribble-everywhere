#!/usr/bin/env bash
# Installs the optional Omarchy bar applet. The daemon works without it.
# Copies the plugin into the user plugin directory and adds it to the bar
# layout when it is not already there. shell.json hot-reloads.
set -euo pipefail
cd "$(dirname "$0")/.."

src="packaging/omarchy/matthewh.palimpsest-ink"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/matthewh.palimpsest-ink"
shell_json="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"

mkdir -p "$dest"
cp -a "$src/manifest.json" "$src/BarWidget.qml" "$dest/"

if [[ ! -f "$shell_json" ]]; then
  echo "No $shell_json — plugin installed at $dest but not added to a bar."
  exit 0
fi

python3 - "$shell_json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    config = json.load(handle)
bar = config.setdefault("bar", {})
layout = bar.setdefault("layout", {})
widget_id = "matthewh.palimpsest-ink"
found = False
for section, entries in layout.items():
    if not isinstance(entries, list):
        continue
    for entry in entries:
        if isinstance(entry, dict) and entry.get("id") == widget_id:
            found = True
if not found:
    layout.setdefault("right", []).insert(0, {"id": widget_id})
    with open(path, "w") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    print(f"Added {widget_id} to the right side of the bar")
else:
    print(f"{widget_id} is already on the bar")
PY

echo "Applet installed at $dest"
