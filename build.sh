#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tunneldesk-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$PROJECT_DIR/TunnelDesk.app"
mkdir -p "$BUILD_DIR/TunnelDesk.app/Contents/MacOS" "$BUILD_DIR/TunnelDesk.app/Contents/Resources"
ARCH="$(uname -m)"
xcrun swiftc -swift-version 5 -O -parse-as-library \
  -target "$ARCH-apple-macosx14.0" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework SwiftUI -framework AppKit -framework Combine \
  "$PROJECT_DIR"/Sources/*.swift \
  -o "$BUILD_DIR/TunnelDesk.app/Contents/MacOS/TunnelDesk"
cp "$PROJECT_DIR/Info.plist" "$BUILD_DIR/TunnelDesk.app/Contents/Info.plist"
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/Resources/AppIcon.icns" "$BUILD_DIR/TunnelDesk.app/Contents/Resources/"
fi
codesign --force --sign - "$BUILD_DIR/TunnelDesk.app"
if [ -d "$APP" ]; then
  rm -rf "$APP"
fi
mv "$BUILD_DIR/TunnelDesk.app" "$APP"
echo "Hazır: $APP"
