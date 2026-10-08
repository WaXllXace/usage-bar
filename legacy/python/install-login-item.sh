#!/bin/zsh
# Install (or reinstall) the menu-bar app as a start-at-login LaunchAgent.
# Run this AFTER `claude-usage --login` has succeeded.
set -e
DIR="${0:A:h}"
PY="$DIR/.venv/bin/python"
PLIST_SRC="$DIR/com.wallace.claude-personal-usage.plist"
LABEL="com.wallace.claude-personal-usage"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__VENV_PYTHON__|$PY|g" \
    -e "s|__TRACKER_PY__|$DIR/tracker.py|g" \
    -e "s|__DIR__|$DIR|g" \
    "$PLIST_SRC" > "$DEST"

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"
echo "Installed and loaded: $DEST"
echo "The menu-bar app will now start at login (and is starting now)."
echo "To remove later: launchctl unload \"$DEST\" && rm \"$DEST\""
