#!/bin/zsh
# Copy the bundle to ~/Applications, retire older versions, and launch it.
# Enable "Launch at login" from the app's ⚙︎ menu.
set -e
ROOT="${0:A:h:h}"
SRC="$ROOT/build/Usage Bar.app"
DEST="$HOME/Applications/Usage Bar.app"
[ -d "$SRC" ] || { echo "Run scripts/bundle.sh first"; exit 1; }

# Retire the legacy single-profile trackers and the previous app name.
OLD="$HOME/Library/LaunchAgents/com.wallace.claude-personal-usage.plist"
if [ -f "$OLD" ]; then
  launchctl unload "$OLD" 2>/dev/null || true
  rm -f "$OLD"
  echo "Removed legacy LaunchAgent"
fi
pkill -x claude-personal-usage 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true
pkill -x UsageBar 2>/dev/null || true
if [ -d "$HOME/Applications/Claude Usage.app" ]; then
  rm -rf "$HOME/Applications/Claude Usage.app"
  echo "Removed Claude Usage.app (re-enable Launch at login in the new app; remove the old entry in System Settings › General › Login Items if it lingers)"
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
open "$DEST"
echo "Installed and launched: $DEST"
