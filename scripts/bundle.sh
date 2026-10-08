#!/bin/zsh
# Build the release binary and assemble "Claude Usage.app" in build/.
set -e
ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release 2>&1 | tail -3

APP="$ROOT/build/Claude Usage.app"
BIN="$ROOT/.build/release/ClaudeUsage"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeUsage"

# App icon from assets/icon-source.png
ICON_KEY=""
if [ -f "$ROOT/assets/icon-source.png" ]; then
  SET="$ROOT/build/AppIcon.iconset"; rm -rf "$SET"; mkdir -p "$SET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$ROOT/assets/icon-source.png" --out "$SET/icon_${sz}x${sz}.png" >/dev/null 2>&1
    sips -z $((sz*2)) $((sz*2)) "$ROOT/assets/icon-source.png" --out "$SET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="    <key>CFBundleIconFile</key>        <string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Claude Usage</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <key>CFBundleIdentifier</key>      <string>com.wallace.claude-usage</string>
    <key>CFBundleExecutable</key>      <string>ClaudeUsage</string>
$ICON_KEY
    <key>CFBundleVersion</key>         <string>1.0.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP"
