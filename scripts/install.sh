#!/bin/zsh
# Copy the bundle to ~/Applications, retire the old LaunchAgent, and launch it.
# Enable "Launch at login" from the app's ⚙︎ menu (SMAppService).
set -e
ROOT="${0:A:h:h}"
SRC="$ROOT/build/Claude Usage.app"
DEST="$HOME/Applications/Claude Usage.app"
[ -d "$SRC" ] || { echo "Run scripts/bundle.sh first"; exit 1; }

# Retire the legacy Rust/Python tracker's LaunchAgent if present.
OLD="$HOME/Library/LaunchAgents/com.wallace.claude-personal-usage.plist"
if [ -f "$OLD" ]; then
  launchctl unload "$OLD" 2>/dev/null || true
  rm -f "$OLD"
  echo "Removed legacy LaunchAgent"
fi
pkill -x claude-personal-usage 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
open "$DEST"
echo "Installed and launched: $DEST"
