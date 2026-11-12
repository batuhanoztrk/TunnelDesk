#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPARKLE_DIR="$(bash "$PROJECT_DIR/scripts/fetch-sparkle.sh")"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tunneldesk-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$PROJECT_DIR/TunnelDesk.app"
mkdir -p "$BUILD_DIR/TunnelDesk.app/Contents/MacOS" "$BUILD_DIR/TunnelDesk.app/Contents/Resources" "$BUILD_DIR/TunnelDesk.app/Contents/Frameworks"
ARCH="$(uname -m)"
xcrun swiftc -swift-version 5 -O -parse-as-library \
  -target "$ARCH-apple-macosx14.0" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework SwiftUI -framework AppKit -framework Combine -framework ServiceManagement \
  -F "$SPARKLE_DIR" -framework Sparkle \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  "$PROJECT_DIR"/Sources/*.swift \
  -o "$BUILD_DIR/TunnelDesk.app/Contents/MacOS/TunnelDesk"
cp "$PROJECT_DIR/Info.plist" "$BUILD_DIR/TunnelDesk.app/Contents/Info.plist"
ditto "$SPARKLE_DIR/Sparkle.framework" "$BUILD_DIR/TunnelDesk.app/Contents/Frameworks/Sparkle.framework"
cp "$PROJECT_DIR/LICENSES/Sparkle.txt" "$BUILD_DIR/TunnelDesk.app/Contents/Resources/Sparkle-LICENSE.txt"
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/Resources/AppIcon.icns" "$BUILD_DIR/TunnelDesk.app/Contents/Resources/"
fi
codesign --force --sign - "$BUILD_DIR/TunnelDesk.app"
if [ -d "$APP" ]; then
  rm -rf "$APP"
fi
mv "$BUILD_DIR/TunnelDesk.app" "$APP"
echo "Hazır: $APP"
