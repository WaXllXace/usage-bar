#!/bin/zsh
# Install the Rust menu-bar app as a start-at-login LaunchAgent.
# Run ./bundle.sh first.
set -e
DIR="${0:A:h}"
LABEL="com.wallace.claude-personal-usage"
BIN="$DIR/Claude Usage (Personal).app/Contents/MacOS/claude-personal-usage"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -x "$BIN" ] || { echo "Binary missing — run ./bundle.sh first"; exit 1; }

cat > "$DEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$LABEL</string>
    <key>ProgramArguments</key> <array><string>$BIN</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>StandardErrorPath</key><string>$DIR/tracker.log</string>
    <key>StandardOutPath</key>  <string>$DIR/tracker.log</string>
</dict>
</plist>
PLIST

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"
echo "Installed and loaded: $DEST"
echo "Remove later: launchctl unload \"$DEST\" && rm \"$DEST\""
