#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?Usage: prepare-release.sh OUTPUT_DIRECTORY [RELEASE_NOTES_FILE]}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SPARKLE_DIR="$(bash "$PROJECT_DIR/scripts/fetch-sparkle.sh")"
ACCOUNT="tr.tunneldesk.mac.updates"
PUBLIC_KEY="$("$SPARKLE_DIR/bin/generate_keys" --account "$ACCOUNT" -p)"
EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PROJECT_DIR/Info.plist")"
if [ "$PUBLIC_KEY" != "$EXPECTED_KEY" ]; then
  echo "Signing key does not match Info.plist. Use the original TunnelDesk signing key." >&2
  exit 1
fi
bash "$PROJECT_DIR/build.sh"
APP="$PROJECT_DIR/TunnelDesk.app"
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
ARCHIVE="$OUT/TunnelDesk-$VERSION-macOS-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
SIGNATURE="$("$SPARKLE_DIR/bin/sign_update" --account "$ACCOUNT" -p "$ARCHIVE")"
"$SPARKLE_DIR/bin/sign_update" --account "$ACCOUNT" --verify "$ARCHIVE" "$SIGNATURE"
if [ -n "${2:-}" ]; then
  python3 "$PROJECT_DIR/scripts/make-appcast.py" --archive "$ARCHIVE" --signature "$SIGNATURE" --output "$OUT/appcast.xml" --notes "$2"
else
  python3 "$PROJECT_DIR/scripts/make-appcast.py" --archive "$ARCHIVE" --signature "$SIGNATURE" --output "$OUT/appcast.xml"
fi
"$SPARKLE_DIR/bin/sign_update" --account "$ACCOUNT" "$OUT/appcast.xml"
"$SPARKLE_DIR/bin/sign_update" --account "$ACCOUNT" --verify "$OUT/appcast.xml"
python3 - "$OUT" "$VERSION" "$ARCH" <<'PY'
import hashlib,pathlib,sys
directory,version,arch=pathlib.Path(sys.argv[1]),sys.argv[2],sys.argv[3]
names=[f'TunnelDesk-{version}-macOS-{arch}.zip','appcast.xml']
text=''.join(hashlib.sha256((directory/name).read_bytes()).hexdigest()+'  '+name+'\n' for name in names)
(directory/f'TunnelDesk-{version}-SHA256SUMS.txt').write_text(text)
PY
printf 'Release assets prepared: %s\n' "$OUT"
