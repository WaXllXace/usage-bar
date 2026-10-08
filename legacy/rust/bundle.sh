#!/bin/zsh
# Build the release binary and assemble it into a .app bundle.
set -e
DIR="${0:A:h}"
cd "$DIR"
source "$HOME/.cargo/env"

cargo build --release

APP="$DIR/Claude Usage (Personal).app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp target/release/claude-personal-usage "$APP/Contents/MacOS/claude-personal-usage"

# Regenerate AppIcon.icns from icon-source.png so the icon survives rebuilds.
ICON_KEY=""
if [ -f "$DIR/icon-source.png" ]; then
  rm -rf "$DIR/AppIcon.iconset"; mkdir "$DIR/AppIcon.iconset"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$DIR/icon-source.png" --out "$DIR/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null 2>&1
    sips -z $((sz*2)) $((sz*2)) "$DIR/icon-source.png" --out "$DIR/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$DIR/AppIcon.iconset" -o "$DIR/AppIcon.icns"
  cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="    <key>CFBundleIconFile</key>        <string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Claude Usage (Personal)</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage (Personal)</string>
    <key>CFBundleIdentifier</key>      <string>com.wallace.claude-personal-usage</string>
    <key>CFBundleExecutable</key>      <string>claude-personal-usage</string>
$ICON_KEY
    <key>CFBundleVersion</key>         <string>0.1.0</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>10.15</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "Built: $APP"
