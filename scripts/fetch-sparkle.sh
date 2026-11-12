#!/bin/bash
set -euo pipefail
VERSION="2.10.1"
SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
CACHE="${TUNNELDESK_BUILD_CACHE:-${TMPDIR:-/tmp}/TunnelDesk-build-dependencies}"
DEST="$CACHE/Sparkle-$VERSION"
if [ -d "$DEST/Sparkle.framework" ] && [ -x "$DEST/bin/sign_update" ] && [ -f "$DEST/.verified-$SHA256" ]; then
  printf '%s\n' "$DEST"
  exit 0
fi
mkdir -p "$CACHE"
chmod 700 "$CACHE"
STAGE="$(mktemp -d "$CACHE/.sparkle.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
  --output "$STAGE/Sparkle.tar.xz"
printf '%s  %s\n' "$SHA256" "$STAGE/Sparkle.tar.xz" | shasum -a 256 --check --status
mkdir "$STAGE/extracted"
tar -xJf "$STAGE/Sparkle.tar.xz" -C "$STAGE/extracted"
touch "$STAGE/extracted/.verified-$SHA256"
if [ -e "$DEST" ]; then rm -rf "$DEST"; fi
mv "$STAGE/extracted" "$DEST"
printf '%s\n' "$DEST"
