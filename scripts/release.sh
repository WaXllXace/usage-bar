#!/bin/zsh
# Build and zip the app for a GitHub Release: build/UsageBar-<version>.zip
set -e
ROOT="${0:A:h:h}"
VERSION="${VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)}"
export VERSION
"$ROOT/scripts/bundle.sh"
ZIP="$ROOT/build/UsageBar-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/build/Usage Bar.app" "$ZIP"
echo "Release archive: $ZIP"
echo "Publish with: gh release create v$VERSION \"$ZIP\" --title \"Usage Bar $VERSION\" --notes-file CHANGELOG.md"
