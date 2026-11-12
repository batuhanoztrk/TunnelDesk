#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
OUT="${1:?Usage: publish-release.sh OUTPUT_DIRECTORY RELEASE_NOTES_FILE}"
NOTES="${2:?Release notes file is required}"
if [ -n "$(git status --porcelain)" ]; then
  echo "Commit and push your changes before publishing." >&2
  exit 1
fi
COMMIT="$(git rev-parse HEAD)"
REMOTE_COMMIT="$(gh api repos/batuhanoztrk/TunnelDesk/commits/main --jq .sha)"
if [ "$COMMIT" != "$REMOTE_COMMIT" ]; then
  echo "Local HEAD must match GitHub main before publishing." >&2
  exit 1
fi
bash "$PROJECT_DIR/scripts/prepare-release.sh" "$OUT" "$NOTES"
OUT="$(cd "$OUT" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")"
ARCH="$(uname -m)"
gh release create "v$VERSION" --repo batuhanoztrk/TunnelDesk --draft --target "$COMMIT" \
  --title "TunnelDesk v$VERSION" --notes-file "$NOTES" \
  "$OUT/TunnelDesk-$VERSION-macOS-$ARCH.zip" "$OUT/appcast.xml" "$OUT/TunnelDesk-$VERSION-SHA256SUMS.txt"
# The latest feed becomes visible only after all update assets are uploaded.
gh release edit "v$VERSION" --repo batuhanoztrk/TunnelDesk --draft=false --latest
