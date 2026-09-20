#!/usr/bin/env bash
# Push the working tree into the live plugin directory.
#
# Omarchy watches ~/.config/omarchy/plugins with inotify and reloads itself, so
# there is nothing to restart. A symlink would be simpler but the manifest
# validator rejects symlinks anywhere inside a plugin folder, hence the copy.
set -euo pipefail

PLUGIN_ID="pinta365.nothing-control"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

mkdir -p "$DEST"
rsync -a --delete --delete-excluded \
  --exclude '.git' \
  --exclude '__pycache__' \
  --exclude 'tests' \
  --exclude 'knowledge' \
  --exclude 'dev.sh' \
  --exclude 'README.md' \
  --exclude 'LICENSE' \
  --exclude '.gitignore' \
  "$SRC/" "$DEST/"

echo "synced -> $DEST"
omarchy plugin validate "$DEST"

# Editing a file in place is picked up by the shell's inotify watch, but that
# only re-evaluates the QML -- it does not rebuild the bar widget or re-register
# IPC handlers. Anything structural (a new property, a new IPC method, a changed
# implicit size) needs a real restart to take effect.
if [[ "${1:-}" == "--restart" ]]; then
  omarchy-restart-shell
  echo "shell restarted"
else
  echo "note: pass --restart for structural changes (new properties, IPC methods)"
fi
